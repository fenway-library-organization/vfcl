package App::Vfcl;

use JSON;
use MARC::Loop;
use LWP::UserAgent;
use Fcntl qw(:seek);
use File::Basename qw(dirname basename);
use Hash::Flatten qw(:all);
use POSIX qw(setuid);
use Cwd qw(getcwd realpath);
use File::Spec;
use File::Copy qw(copy move);
use Try::Tiny;
use Getopt::Long
    qw(:config posix_default gnu_compat require_order bundling no_ignore_case);

sub usage;
sub fatal;

use vars qw($VERSION);

$VERSION = '0.01';

my $ua = LWP::UserAgent->new;
my $json = JSON->new;
my $tmpcounter = 0;
my $curi;  # Current VuFind instance ID
my ($verbose, $dryrun);

# --- Methods

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub run {
    usage if !@ARGV;
    my $cmd = shift @ARGV;
    goto &{ __PACKAGE__->can('cmd_'.$cmd) || usage };
}

# --- Command handlers

sub cmd_new {
    #@ new [-s SOLRHOST:SOLRPORT] INSTANCE
    my $solr = 'localhost:8080';
    my ($descrip, %source);
    orient(
        'nix' => 1,  # Don't try to get an instance
        's|solr=s' => \$solr,
        'm|description=s' => \$descrip,
        'r|release=s' => sub {
            $source{'type'} = 'release';
            $source{'version'} = $_[1];
            $source{'file'} = "$root/release/vufind-$_[1].tar.gz";
            $source{'uri'} = "https://github.com/vufind-org/vufind/releases/download/v$_[1]/vufind-$_[1].tar.gz",
        },
        'G|git-branch=s' => sub {
            $source{'type'} = 'git';
            $source{'repo'} = '../../devel';
            $source{'branch'} = $_[1];
        },
    );
    usage if @ARGV != 1;
    my ($i) = @ARGV;
    fatal "root doesn't exist: $root"
        if !-d $root;
    fatal "instance already exists: $i"
        if -e "$root/instance/$i/instance.kv";
    $solr =~ /^(\[[^\[\]]+\]|[^:]+):([0-9]+)$/
        or usage;
    my %solr = ('host' => $1, 'port' => $2);
    if (!defined $descrip) {
        if (-t STDIN && -t STDERR) {
            print STDERR "Instance description: ";
            $descrip = <STDIN>;
            fatal "cancelled" if !defined $descrip;
            chomp $descrip;
        }
    }
    my $instance = App::Vfcl::Instance->create(
        'id' => $i,
        'description' => $descrip,
        'source' => \%source,
        'solr' => \%solr,
    );
    print STDERR qq{instance $i created -- use "$prog build" to make it work\n};
}

sub cmd_status {
    #@ status [INSTANCE...]
    orient('nix' => 1);
    @ARGV = all_instances() if !@ARGV;
    foreach my $i (@ARGV) {
        my $instance = instance($i);
        show_status($instance);
    }
}

sub cmd_build {
    #@ build INSTANCE
    my $instance = orient(
        'n|dry-run' => \$dryrun,
        'v|verbose' => \$verbose,
    );
    $verbose = 1 if $dryrun;
    try {
        $instance->build;
    }
    catch {
        fatal(split /\n/, $@, 1);
    }
}

sub cmd_cache {
    subcmd();
}

sub cmd_cache_empty {
    my $instance = orient();
    my @dirs = grep { -d $_ } glob("$instance->{'_directory'}/vufind/local/cache/*");
    system('rm', '-Rf', @dirs);
}

sub cmd_solr {
    subcmd();
}

sub cmd_solr_start {
    my $instance = orient();
    usage if @ARGV;
    solr_action($instance, 'start');
}

sub cmd_solr_stop {
    my $instance = orient();
    usage if @ARGV;
    solr_action($instance, 'stop');
}

sub cmd_solr_restart {
    my $instance = orient();
    usage if @ARGV;
    solr_action($instance, 'restart');
}

sub cmd_solr_status {
    my $instance = orient();
    usage if @ARGV;
    my $solr = solr($instance);
    my $status = solr_status($solr);
    if (!$status) {
        print STDERR "solr instance is not running: $solr->{'uri'}\n";
        exit 2;
    }
    elsif ($status->{'is_running'}) {
        print STDERR "solr instance is running: $solr->{'uri'}\n";
    }
    else {
        print STDERR "solr instance returned an error: $solr->{'uri'}\n";
        exit 3;
    }
}

sub cmd_import {
    #@ import FILE...
    my $instance = orient(
        'n|dry-run' => \$dryrun,
        'v|verbose' => \$verbose,
    );
    usage if !@ARGV;
    my $solr = solr($instance);
    @ARGV = map {
        my $path = canonpath($_);
        fatal "no such file: $_" if !defined $path;
        $path
    } @ARGV;
    $verbose = 1, print STDERR "Dry run -- no changes will be made\n" if $dryrun;
    print STDERR "Checking MARC records...\n";
    my %invalid;
    my %name;
    foreach my $f (@ARGV) {
        print STDERR $f, "\n" if $verbose;
        fatal "not a MARC file: $f" if $f !~ m{([^/]+\.mrc)(?:\.gz)?$};
        my $name = $1;
        fatal "duplicate file name: $name" if exists $name{$name};
        $name{$f} = $name;
        my $fh = oread($f);
        my %num;
        while (1) {
            my $marc;
            { local $/ = "\x1d"; $marc = <$fh> }
            last if !defined $marc;
            $num{'status'}{   substr($marc, 5, 1) }++;
            $num{'type'}{     substr($marc, 6, 1) }++;
            $num{'biblevel'}{ substr($marc, 7, 1) }++;
            $num{'encoding'}{ substr($marc, 9, 1) }++;
        }
        delete $num{'status'  }{$_} for qw(a c n p);
        delete $num{'type'    }{$_} for qw(a c d e f g i j k m o p r t);
        delete $num{'biblevel'}{$_} for qw(a c n p i m s);
        delete $num{'encoding'}{$_} for qw(a);
        while (my ($what, $counts) = each %num) {
            my @bad = keys %$counts;
            if (@bad) {
                print STDERR "  ERR $f :: some records have an invalid $what: ", join(', ', @bad), "\n";
                $invalid{$f}++;
            }
        }
        if (!$invalid{$f}) {
            system(qw(marcdiag -eOsoq), @ARGV) == 0
                or $invalid{$f}++;
        }
        if ($invalid{$f}) {
            print STDERR "  ERR $f\n";
        }
        else {
            print STDERR "  OK  $f\n" if $verbose;
        }
    }
    exit 1 if keys %invalid;
    xchdir($root, 'instance', $instance->{'id'});
    my $solr_dir = canonpath($solr->{'local'});
    fatal "solr instance doesn't exist locally"
        if !defined $solr_dir
        || !-d $solr_dir;
    my $solr_dir_here = 'vufind/solr';
    fatal getcwd, '/solr does not exist'
        if !-e $solr_dir_here;
    $solr_dir_here = canonpath(readlink($solr_dir_here)) if -l $solr_dir_here;
    fatal "solr not configured correctly: $solr_dir_here is not the same as $solr_dir"
        if $solr_dir_here ne $solr_dir;
    exit 0 if $dryrun;
    xmkdir('records', 'records/importing', 'records/imported', 'records/failed');
    my @importing;
    foreach my $f (@ARGV) {
        my $name = $name{$f};
        my $dest = "records/importing";
        xmove($f, $dest);
        if ($f =~ /\.gz$/) {
            system('gunzip', "$dest.gz") == 0
                or fatal "decompression failed: $dest.gz";
        }
        my $path = canonpath("$dest/$name");
        push @importing, $path;
    }
    xchdir('vufind');
    my $err;
    withenv(environment($instance), sub {
        $err = system('./import-marc.sh', @importing);
    });
    xchdir('..');
    if ($err) {
        print STDERR "import failed\n";
        xmove(@importing, 'records/failed');
    }
    else {
        print STDERR "import completed\n";
        xmove(@importing, 'records/imported');
    }
}

sub cmd_export {
    #@ export [-a] [-k BATCHSIZE] INSTANCE [RECORD...]
    my %form = qw(fl fullrecord start 0 rows 10);
    my $all;
    my $instance = orient(
        'a|all' => \$all,
        'k|batch-size=i' => \$form{'rows'},
    );
    my $total = 0;
    my @queries;
    if ($all) {
        usage if @ARGV;
        $form{'q'} = 'id:*';
        push @queries, { %form };
    }
    else {
        if (!@ARGV) {
            @ARGV = <STDIN>;
            chomp @ARGV;
        }
        while (@ARGV) {
            my @ids = splice @ARGV, 0, $form{'rows'};
            my $ids = join(' || ', map { 'id:' . $_ } @ids);
            $form{'q'} = $ids;
            push @queries, { %form };
            $form{'start'} += @ids;
        }
    }
    my $solr = solr($instance);
    my $uri = $solr->{'uri'};
    my $bibcore = $solr->{'cores'}{'biblio'};
    foreach my $query (@queries) {
        my $remaining;
        my $uri = URI->new("$uri/${bibcore}/select");
        while (!defined($remaining) || $remaining > 0) {
            $uri->query_form(%$query);
            my $req = HTTP::Request->new('GET' => $uri);
            $req->header('Accept' => 'application/json');
            my $res = $ua->request($req);
            fatal $res->status_line if !$res->is_success;
            my $content = $json->decode($res->content);
            if (!defined $remaining) {
                $remaining = $content->{'response'}{'numFound'};
            }
            my @records = @{ $content->{'response'}{'docs'} };
            my $n = @records;
            last if $n == 0;
            print $_->{'fullrecord'} for @records;
            $remaining -= $n;
            $query->{'start'} += $n;
            $total += $n;
        }
    }
}

# --- Commands that operate more directly on Solr

sub cmd_empty {
    my $yes;
    my $instance = orient(
        'y|yes' => \$yes,
    );
    usage if @ARGV;
    my $solr = solr($instance);
    my ($host, $port, $cores) = @$solr{qw(host port cores)};
    my $uri = "http://${host}:${port}/solr/$cores->{'biblio'}/update";
    my $sfx = "?commit=true";
    print STDERR "Deleting all records from Solr index $uri ...\n";
    if (!$yes) {
        print STDERR 'Are you sure you want to proceed? [yN] ';
        my $ans = <STDIN>;
        fatal 'cancelled' if !defined $ans || $ans !~ /^[Yy]/;
    }
    my $t0 = time;
    $uri .= $sfx;
    my $req = HTTP::Request->new('POST' => $uri);
    $req->header('Content-Type' => 'text/xml');
    $req->content('<delete><query>*:*</query></delete>');
    my $res = $ua->request($req);
    fatal $res->status_line if !$res->is_success;
    printf STDERR "Deletion completed in %d second(s)\n", time - $t0;
}

sub cmd_upgrade {
    update_ini_file('config/vufind/config.ini', 'System', sub {
        s/^(\s*autoConfigure\s*)=(\s*)false/$1=$2true/;
    });
}

# --- Other functions

sub subcmd {
    usage if !@ARGV;
    my $subcmd = shift @ARGV;
    my @caller = caller 1;
    $caller[3] =~ /(cmd_\w+)$/ or die;
    goto &{ __PACKAGE__->can($1.'_'.$subcmd) || usage };
}

sub solr_status {
    my ($solr) = @_;
    my $uri = "$solr->{'uri'}/admin/cores?action=STATUS";
    my $req = HTTP::Request->new(GET => $uri);
    $req->header('Accept' => 'application/json');
    my $res = $ua->request($req)
        or return;
    my %status = (
        'http_code' => $res->code,
        'http_status_line' => $res->status_line,
    );
    my $content = try { $json->decode($res->content) };
    if ($res->is_success && defined $content) {
        %status = (
            %status,
            'is_running' => 1,
            'cores' => $content->{'status'},
        );
    }
    return \%status;
}

sub solr_action {
    my ($instance, $action) = @_;
    $instance = instance($instance) if !ref $instance;
    my $i = $instance->{'id'};
    my $idir = $instance->{'_directory'};
    as_solr_user($instance, sub {
        system("$idir/vufind/solr.sh", $action) == 0
            or fatal "exec $idir/solr.sh $action: $?";
    });
}

sub as_solr_user {
    my ($instance, $cmd) = @_;
    my $i = $instance->{'id'};
    my $solr = solr($instance);
    my ($host, $port) = @$solr{qw(host port)};
    my $solr_dir = $solr->{'local'};
    fatal "solr instance for $i doesn't seem to exist locally"
        if !defined $solr_dir || !-d $solr_dir;
    my $solr_user = $solr->{'user'} || 'solr';
    my $user = getpwuid($<);
    if ($user ne $solr_user) {
        my $solr_uid = getpwnam($solr_user);
        fatal "getpwnam: $!" if !defined $solr_uid;
        setuid($solr_uid) or fatal "setuid $solr_uid: $!";
    }
    withenv(environment($instance), sub { $cmd->($solr) });
}

sub environment {
    my ($instance, $sub) = @_;
    my $vdir = $instance->{'_directory'} . '/vufind';
    my $solr_dir = solr($instance)->{'local'};
    my %solr;
    %solr = (
        'SOLR_HOME' => "$solr_dir/vufind",
        'SOLR_BIN' => "$solr_dir/vendor/bin",
        'SOLR_LOGS_DIR' => "$solr_dir/vufind/logs",
    ) if defined($solr_dir) && -d $solr_dir;
    return {
        %ENV,
        'VUFIND_HOME' => $vdir,
        'VUFIND_LOCAL_DIR' => "$vdir/local",
        %solr,
    };
}

sub withenv {
    my ($env, $sub) = @_;
    local %ENV = %$env;
    $sub->();
}

sub oread {
    my ($file) = @_;
    open my $fh, '<', $file or fatal "open $file for reading: $!";
    return $fh;
}

sub owrite {
    my ($file) = @_;
    open my $fh, '>', $file or fatal "open $file for writing: $!";
    return $fh;
}

sub oreadwrite {
    my ($file) = @_;
    open my $fh, '+<', $file or fatal "open $file for reading and writing: $!";
    return $fh;
}

sub kvmake {
    my ($hash) = @_;
    my %kv = map { $_ => $hash->{$_} } grep { !/^_/ } keys %$hash;
    return flatten(\%kv);
}

sub show_status {
    my ($instance) = @_;
    my $solr = solr($instance);
    my $uri = $solr->{'uri'};
    my $req = HTTP::Request->new('GET' => $uri);
    my $res = $ua->request($req);
    print $res->status_line, "\n";
}

sub xmkdir {
    foreach my $dir (@_) {
        -d $dir or mkdir $dir or fatal "mkdir $dir: $!";
    }
}

sub xmove {
    my $d = pop;
    foreach my $s (@_) {
        move($s, $d)
            or fatal "move $s $d: $!";
    }
}

sub xrename {
    my ($s, $d) = @_;
    rename $s, $d or fatal "rename $s to $d: $!";
}

sub xchdir {
    foreach my $dir (@_) {
        chdir $dir or fatal "chdir $dir: $!";
    }
}

sub update_ini_file {
    my ($file, $section, $sub) = @_;
    my $fhin = oread($file);
    my @lines = <$fhin>;
    my $n = 0;
    my $insection = '';
    my ($seen, $done);
    for (@lines) {
        last if $done;
        if (/^\s*;/) {
            next;  # Don't do anything with comments
        }
        elsif (/^\[(\S+)\]$/) {
            if ($insection eq $section) {
                # End of the desired section
                my $end = '';
                for ($end) {
                    $n++ if $sub->();
                }
                $done = 1;
            }
            else {
                $insection = $1;
                if ($insection eq $section) {
                    # Beginning of the desired section
                    $seen = 1;
                    $n++ if $sub->($_);
                }
            }
        }
        elsif ($insection eq $section && /^\s*([^=]+)=(.*)$/) {
            # Assignment within the desired section
            my ($k, $v) = ($1, $2);
            $k =~ s/^\s+|\s+$//g;
            $v =~ s/^\s+|\s+$//g;
            $n++ if $sub->($k, $v);
        }
    }
    if (!$seen) {
        # Add the section
        my $head = "[$section]\n";
        push @lines, $head;
        for ($head) {
            $n++ if $sub->($head);
        }
        $insection = $section;
    }
    if (!$done) {
        # End of the desired section
        my $end = '';
        for ($end) {
            $n++ if $sub->();
        }
    }
    if ($n) {
        my $tmpfile = '.~' . $file . '~';
        my $fhout = owrite($tmpfile);
        for (@lines) {
            print $fhout $_ if defined $_;
        }
        close $fhout or fatal "close $tmpfile: $!";
        replace($file, $tmpfile, $file . '.bak');
    }
    return 0;
}

sub tmpfile {
    my ($file) = @_;
    my $dir = dirname($file);
    my $base = basename($file);
    return $dir . '/.~' . ++$tmpcounter . '~' . $base . '~';
}

sub replace {
    # Replace the contents of $file with the contents of $new -- leaving a copy
    # of the original $file in $backup, if the latter is specified
    my ($file, $new, $backup) = @_;
    if (!defined $backup) {
        my $tmp = tmpfile();
        rename $file, $tmp or fatal "replace $file: can't move it to make way for new contents";
        if (rename $new, $file) {
            unlink $tmp;
            return;
        }
        rename $tmp, $file or fatal "replace $file: can't move it back from $tmp";
    }
    if (-e $backup) {
        unlink $backup or fatal "unlink $backup"
    }
    if (rename $file, $backup) {
        return if rename $new, $file;
        rename $backup, $file
            or fatal "replace $file: can't restore from $backup: $!";
    }
    else {
        fatal "replace $file: can't rename $file to $backup: $!";
    }
}

sub instance {
    my ($i) = @_;
    if (!defined $i) {
        $i = $curi or fatal "no instance specified";
    }
    $i =~ s/^[@]//;
    my $instance = kvread("$root/instance/$i/instance.kv");
    return App::Vfcl::Instance->new(
        'id' => $i,
        %$instance,
        '_ua' => $ua,
        '_json' => $json,
        '_directory' => "$root/instance/$i",
    );
}

sub solr {
    my ($i) = @_;
    my $instance;
    if (ref $i) {
        $instance = $i;
        $i = $instance->{'id'};
    }
    else {
        $instance = instance($i);
    }
    my $idir = $instance->{'_directory'};
    my $solr = $instance->{'solr'} ||= kvread("$idir/solr.kv");
    my $host = $solr->{'host'} ||= 'localhost';
    my $port = $solr->{'port'} ||= 8080;
    my ($solr_dir) = grep { -d } map { "/var/local/solr/$_" } $i, $port;
    $solr->{'local'} = $solr_dir if defined $solr_dir;
    $solr->{'root'} ||= $solr_root;
    $solr->{'uri'} ||= "http://${host}:${port}/solr";
    my $cores = $solr->{'cores'} ||= {};
    foreach (qw(authority biblio reserves website)) {
        $cores->{$_} ||= $_;
    }
    return $solr;
}

sub kvread {
    my ($f) = @_;
    my $fh = oread($f);
    my %kv;
    while (<$fh>) {
        if (/^(\S+)\s+(.*)$/) {
            my ($k, $v) = ($1, $2);
            my $hash = \%kv;
            while ($k =~ s/^([^.]+)\.//) {
                $hash = $hash->{$1} ||= {};
            }
            $hash->{$k} = $v;
        }
        else {
            chomp;
            fatal "unparseable: config file $f line $.: $_";
        }
    }
    return \%kv;
}

sub kvwrite {
    my $f = shift;
    my $kv = kvmake(shift);
    my $fh = owrite($f);
    foreach my $k (sort keys %$kv) {
        my $v = $kv->{$k};
        printf $fh "%s %s\n", $k, $v if defined $v;
    }
}

sub canonpath {
    return if !defined $_[0];
    return realpath(File::Spec->rel2abs(@_));
}

sub orient {
    my %arg = @_;
    my $dont_return_instance = delete $arg{'nix'};
    GetOptions(
        %arg,
    ) or usage;
    return if $dont_return_instance;
    my $argvi;
    if (@ARGV && -e "$root/$ARGV[0]/instance.kv") {
        $argvi = $ARGV[0];
    }
    if (getcwd =~ m{^\Q$root\E/instance/+([^/]+)}) {
        $curi = $1;
    }
    return instance(shift @ARGV) if $argvi && !$curi;
    return instance($curi) if $curi && !$argvi;
    return instance($argvi) if $argvi;
    # xchdir($root);
}

sub usage {
    print STDERR "usage: vfop COMMAND [ARG...]\n";
    exit 1;
}

sub fatal {
    print STDERR "vfop: ", @_, "\n";
    exit 2;
}

1;
