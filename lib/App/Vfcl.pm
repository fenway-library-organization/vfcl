package App::Vfcl;

use strict;
use warnings;

use App::Vfcl::Instance;
use App::Vfcl::Util;

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

use constant util => 'App::Vfcl::Util';

use vars qw($VERSION $AUTOLOAD);
$VERSION = '0.01';

# --- Methods

sub new {
    my $cls = shift;
    my $self = bless {
        'program_name' => basename($0),
        'root' => $ENV{'VFCL_ROOT'} || '/usr/local/vufind',
        'solr_root' => $ENV{'VFCL_SOLR_ROOT'} || '/var/local/solr',
        'counter' => 0,
        @_,
    }, $cls;
    $self->init;
    return $self;
}

sub init {
    my ($self) = @_;
    $self->{'ua'} ||= LWP::UserAgent->new;
    $self->{'json'} ||= JSON->new;
}

sub root { @_ > 1 ? $_[0]{'root'} = $_[1] : $_[0]{'root'} }
sub solr_root { @_ > 1 ? $_[0]{'solr_root'} = $_[1] : $_[0]{'solr_root'} }
sub ua { @_ > 1 ? $_[0]{'ua'} = $_[1] : $_[0]{'ua'} }
sub json { @_ > 1 ? $_[0]{'json'} = $_[1] : $_[0]{'json'} }
sub verbose { @_ > 1 ? $_[0]{'verbose'} = $_[1] : $_[0]{'verbose'} }
sub dryrun { @_ > 1 ? $_[0]{'dryrun'} = $_[1] : $_[0]{'dryrun'} }

sub current_instance { @_ > 1 ? $_[0]{'current_instance'} = $_[1] : $_[0]{'current_instance'} }
sub program_name { @_ > 1 ? $_[0]{'program_name'} = $_[1] : $_[0]{'program_name'} }

sub counter {
    return ++$_[0]{'counter'} if @_ == 1;
    return $_[0]{'counter'} = $_[1];
}

sub file {
    my ($self, $f) = @_;
    return canonpath($f, $self->root);
}

sub run {
    my ($self) = @_;
    usage() if !@ARGV;
    my $cmd = shift @ARGV;
    goto &{ $self->can('cmd_'.$cmd) || usage() };
}

# --- Command handlers

sub cmd_new {
    #@ new [-s SOLRHOST:SOLRPORT] INSTANCE
    my ($self) = @_;
    my $solr = 'localhost:8080';
    my ($descrip, %source);
    my $root = $self->root;
    $self->orient(
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
    usage() if @ARGV != 1;
    my ($i) = @ARGV;
    fatal("root doesn't exist: $root")
        if !-d $root;
    fatal("instance already exists: $i")
        if -e "$root/instance/$i/instance.yml";
    $solr =~ /^(\[[^\[\]]+\]|[^:]+):([0-9]+)$/
        or usage();
    my %solr = ('host' => $1, 'port' => $2);
    if (!defined $descrip) {
        if (-t STDIN && -t STDERR) {
            print STDERR "Instance description: ";
            $descrip = <STDIN>;
            fatal("cancelled") if !defined $descrip;
            chomp $descrip;
        }
    }
    App::Vfcl::Instance->create(
        'id' => $i,
        'app' => $self,
        'description' => $descrip,
        'source' => \%source,
        'solr' => \%solr,
    );
    my $prog = $self->program_name;
    print STDERR qq{instance $i created -- use "$prog build" to make it work\n};
}

sub cmd_status {
    #@ status [INSTANCE...]
    my ($self) = @_;
    $self->orient('nix' => 1);
    @ARGV = $self->all_instances if !@ARGV;
    foreach my $i (@ARGV) {
        $self->show_status($self->instance($i));
    }
}

sub cmd_build {
    #@ build INSTANCE
    my ($self) = @_;
    try {
        my $instance = $self->orient;
        $instance->build;
    }
    catch {
        fatal(split /\n/, $_, 1);
    };
}

sub cmd_cache {
    my ($self) = @_;
    subcmd($self);
}

sub cmd_cache_empty {
    my ($self) = @_;
    my $instance = $self->orient;
    my @dirs = grep { -d $_ } glob("$instance->{'_directory'}/vufind/local/cache/*");
    system('rm', '-Rf', @dirs);
}

sub cmd_solr {
    my ($self) = @_;
    subcmd($self);
}

sub cmd_solr_start {
    my ($self) = @_;
    my $instance = $self->orient;
    usage() if @ARGV;
    $self->solr_action($instance, 'start');
}

sub cmd_solr_stop {
    my ($self) = @_;
    my $instance = $self->orient;
    usage() if @ARGV;
    $self->solr_action($instance, 'stop');
}

sub cmd_solr_restart {
    my ($self) = @_;
    my $instance = $self->orient;
    usage() if @ARGV;
    $self->solr_action($instance, 'restart');
}

sub cmd_solr_status {
    my ($self) = @_;
    my $instance = $self->orient;
    usage() if @ARGV;
    my $solr = $instance->solr;
    my $status = $self->solr_status($solr);
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
    my ($self) = @_;
    my $instance = $self->orient;
    usage() if !@ARGV;
    my $solr = $instance->solr;
    @ARGV = map {
        my $path = canonpath($_);
        fatal("no such file: $_") if !defined $path;
        $path
    } @ARGV;
    print STDERR "Dry run -- no changes will be made\n" if $self->dryrun;
    print STDERR "Checking MARC records...\n";
    my %invalid;
    my %name;
    foreach my $f (@ARGV) {
        print STDERR $f, "\n" if $self->verbose;
        fatal("not a MARC file: $f") if $f !~ m{([^/]+\.mrc)(?:\.gz)?$};
        my $name = $1;
        fatal("duplicate file name: $name") if exists $name{$name};
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
            print STDERR "  OK  $f\n" if $self->verbose;
        }
    }
    exit 1 if keys %invalid;
    my $root = $self->root;
    xchdir($root, 'instance', $instance->{'id'});
    my $solr_dir = canonpath($solr->{'local'});
    fatal("solr instance doesn't exist locally")
        if !defined $solr_dir
        || !-d $solr_dir;
    my $solr_dir_here = 'vufind/solr';
    fatal(getcwd, '/solr does not exist')
        if !-e $solr_dir_here;
    $solr_dir_here = canonpath(readlink($solr_dir_here)) if -l $solr_dir_here;
    fatal("solr not configured correctly: $solr_dir_here is not the same as $solr_dir")
        if $solr_dir_here ne $solr_dir;
    exit 0 if $self->dryrun;
    xmkdir('records', 'records/importing', 'records/imported', 'records/failed');
    my @importing;
    foreach my $f (@ARGV) {
        my $name = $name{$f};
        my $dest = "records/importing";
        xmove($f, $dest);
        if ($f =~ /\.gz$/) {
            system('gunzip', "$dest.gz") == 0
                or fatal("decompression failed: $dest.gz");
        }
        my $path = canonpath("$dest/$name");
        push @importing, $path;
    }
    xchdir('vufind');
    my $err;
    $self->withenv($self->environment($instance), sub {
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
    my ($self) = @_;
    my %form = qw(fl fullrecord start 0 rows 10);
    my $all;
    my $instance = $self->orient(
        'a|all' => \$all,
        'k|batch-size=i' => \$form{'rows'},
    );
    my $total = 0;
    my @queries;
    if ($all) {
        usage() if @ARGV;
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
    my $solr = $instance->solr;
    my $uri = $solr->{'uri'};
    my $bibcore = $solr->{'cores'}{'biblio'};
    my $ua = $self->ua;
    my $json = $self->json;
    foreach my $query (@queries) {
        my $remaining;
        my $uri = URI->new("$uri/${bibcore}/select");
        while (!defined($remaining) || $remaining > 0) {
            $uri->query_form(%$query);
            my $req = HTTP::Request->new('GET' => $uri);
            $req->header('Accept' => 'application/json');
            my $res = $ua->request($req);
            fatal($res->status_line) if !$res->is_success;
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
    my ($self) = @_;
    my $yes;
    my $instance = $self->orient(
        'y|yes' => \$yes,
    );
    usage() if @ARGV;
    my $solr = $instance->solr;
    my ($host, $port, $cores) = @$solr{qw(host port cores)};
    my $uri = "http://${host}:${port}/solr/$cores->{'biblio'}/update";
    my $sfx = "?commit=true";
    print STDERR "Deleting all records from Solr index $uri ...\n";
    if (!$yes) {
        print STDERR 'Are you sure you want to proceed? [yN] ';
        my $ans = <STDIN>;
        fatal('cancelled') if !defined $ans || $ans !~ /^[Yy]/;
    }
    my $t0 = time;
    $uri .= $sfx;
    my $req = HTTP::Request->new('POST' => $uri);
    $req->header('Content-Type' => 'text/xml');
    $req->content('<delete><query>*:*</query></delete>');
    my $ua = $self->ua;
    my $res = $ua->request($req);
    fatal($res->status_line) if !$res->is_success;
    printf STDERR "Deletion completed in %d second(s)\n", time - $t0;
}

sub cmd_upgrade {
    my ($self) = @_;
    $self->update_ini_file('config/vufind/config.ini', 'System', sub {
        s/^(\s*autoConfigure\s*)=(\s*)false/$1=$2true/;
    });
}

# --- Other functions

sub subcmd {
    my ($self) = @_;
    usage() if !@ARGV;
    my $subcmd = shift @ARGV;
    my @caller = caller 1;
    $caller[3] =~ /(cmd_\w+)$/ or die;
    goto &{ $self->can($1.'_'.$subcmd) || usage() };
}

sub solr_status {
    my ($self, $solr) = @_;
    my $uri = "$solr->{'uri'}/admin/cores?action=STATUS";
    my $req = HTTP::Request->new(GET => $uri);
    $req->header('Accept' => 'application/json');
    my $ua = $self->ua;
    my $json = $self->json;
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
    my ($self, $instance, $action) = @_;
    $instance = $self->instance($instance) if !ref $instance;
    my $i = $instance->{'id'};
    my $idir = $instance->{'_directory'};
    $self->as_solr_user($instance, sub {
        system("$idir/vufind/solr.sh", $action) == 0
            or fatal("exec $idir/solr.sh $action: $?");
    });
}

sub as_solr_user {
    my ($self, $instance, $cmd) = @_;
    my $i = $instance->{'id'};
    my $solr = $instance->solr;
    my ($host, $port) = @$solr{qw(host port)};
    my $solr_dir = $solr->{'local'};
    fatal("solr instance for $i doesn't seem to exist locally")
        if !defined $solr_dir || !-d $solr_dir;
    my $solr_user = $solr->{'user'} || 'solr';
    my $user = getpwuid($<);
    if ($user ne $solr_user) {
        my $solr_uid = getpwnam($solr_user);
        fatal("getpwnam: $!") if !defined $solr_uid;
        setuid($solr_uid) or fatal("setuid $solr_uid: $!");
    }
    $self->withenv($self->environment($instance), sub { $cmd->($solr) });
}

sub environment {
    my ($self, $instance, $sub) = @_;
    my $vdir = $instance->{'_directory'} . '/vufind';
    my $solr_dir = $instance->solr->{'local'};
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
    my ($self, $env, $sub) = @_;
    local %ENV = %$env;
    $sub->();
}

sub show_status {
    my ($self, $instance) = @_;
    my $solr = $instance->solr;
    my $uri = $solr->{'uri'};
    my $req = HTTP::Request->new('GET' => $uri);
    my $ua = $self->ua;
    my $res = $ua->request($req);
    print $res->status_line, "\n";
}

sub update_ini_file {
    my ($self, $file, $section, $sub) = @_;
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
        my $fhout = $self->owrite($tmpfile);
        for (@lines) {
            print $fhout $_ if defined $_;
        }
        close $fhout or fatal("close $tmpfile: $!");
        $self->replace($file, $tmpfile, $file . '.bak');
    }
    return 0;
}

sub tmpfile {
    my ($self, $file) = @_;
    my $dir = dirname($file);
    my $base = basename($file);
    my $counter = $self->counter;
    return $dir . '/.~' . $counter . '~' . $base . '~';
}

sub replace {
    # Replace the contents of $file with the contents of $new -- leaving a copy
    # of the original $file in $backup, if the latter is specified
    my ($self, $file, $new, $backup) = @_;
    if (!defined $backup) {
        my $tmp = $self->tmpfile;
        rename $file, $tmp or fatal("replace $file: can't move it to make way for new contents");
        if (rename $new, $file) {
            unlink $tmp;
            return;
        }
        rename $tmp, $file or fatal("replace $file: can't move it back from $tmp");
    }
    if (-e $backup) {
        unlink $backup or fatal("unlink $backup")
    }
    if (rename $file, $backup) {
        return if rename $new, $file;
        rename $backup, $file
            or fatal("replace $file: can't restore from $backup: $!");
    }
    else {
        fatal("replace $file: can't rename $file to $backup: $!");
    }
}

sub instance {
    my ($self, $i) = @_;
    if (!defined $i) {
        $i = $self->current_instance or fatal("no instance specified");
    }
    $i =~ s/^[@]//;
    my $root = $self->root;
    my $ua = $self->ua;
    my $json = $self->json;
    return App::Vfcl::Instance->new(
        'id' => $i,
        'app' => $self,
        'ua' => $ua,
        'root' => "$root/instance/$i",
    );
}

sub solr {
    my ($self, $i) = @_;
    my $instance;
    if (ref $i) {
        $instance = $i;
        $i = $instance->{'id'};
    }
    else {
        $instance = $self->instance($i);
    }
    return $instance->solr;
}

sub orient {
    my ($self, %arg) = @_;
    my $dont_return_instance = delete $arg{'nix'};
    GetOptions(
        'n|dry-run' => \$self->{'dryrun'},
        'v|verbose' => \$self->{'verbose'},
        %arg,
    ) or usage();
    $self->{'verbose'} = 1 if $self->{'dryrun'};
    return if $dont_return_instance;
    my $root = $self->root;
    my ($argvi, $curi);
    if (@ARGV && -e "$root/instance/$ARGV[0]/instance.yml") {
        $argvi = $ARGV[0];
    }
    if (getcwd =~ m{^\Q$root\E/instance/+([^/]+)}) {
        $curi = $1;
    }
    my $i;
    if ($argvi && !$curi) {
        $i = $argvi;
        shift @ARGV;
    }
    elsif ($curi && !$argvi) {
        $i = $curi;
    }
    elsif ($argvi) {
        $i = $argvi;
    }
    else {
        fatal("can't determine instance");
    }
    $self->current_instance($self->instance($i));
}

### sub AUTOLOAD {
###     if (@_ && ref($_[0]) && $_[0]->isa(__PACKAGE__)) {
###         shift;
###     }
###     (my $method = $AUTOLOAD) =~ s/.*:://;
###     if (defined(my $sub = App::Vfcl::Util->can($method))) {
###         try {
###             $sub->(@_);
###         }
###         catch {
###             fatal($@);
###         };
###     }
###     else {
###         fatal("internal error: function $method not found");
###     }
### }

1;
