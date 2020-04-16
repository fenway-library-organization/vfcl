package App::Vfcl::Instance;

use strict;
use warnings;

use base qw(App::Vfcl::Object);

use App::Vfcl::Util;

sub init {
    my ($self) = @_;
    my $f = $self->file('instance.yml');
    $self->init_from_file($f);
}

sub _private_members { qw(app directory ua) }

sub id { @_ > 1 ? $_[0]{'id'} = $_[1] : $_[0]{'id'} }
sub database { @_ > 1 ? $_[0]{'database'} = $_[1] : $_[0]{'database'} }
sub hostname { @_ > 1 ? $_[0]{'hostname'} = $_[1] : $_[0]{'hostname'} }
sub source { @_ > 1 ? $_[0]{'source'} = $_[1] : $_[0]{'source'} }
sub app { @_ > 1 ? $_[0]{'app'} = $_[1] : $_[0]{'app'} }
sub ua { @_ > 1 ? $_[0]{'ua'} = $_[1] : $_[0]{'ua'} }

sub create {
    my $cls = shift;
    my $self = ref($cls) ? $cls : $cls->new(@_);
    my $root = $self->app->root;
    my $id = $self->id;
    $self->create_with_file("$root/instance/$id/instance.yml");
}

sub yml {
    my ($self, $name, $yml) = @_;
    if ($yml) {
        ymlwrite($self->path($name . '.yml'), $yml);
    }
    else {
        ymlread($self->file($name . '.yml'));
    }
}

sub solr {
    my $self = shift;
    return $self->{'solr'} = shift if @_;
    my $id = $self->id;
    my $idir = $self->path;
    my $solr = $self->{'solr'} ||= $self->yml('solr');
    my $host = $solr->{'host'} ||= 'localhost';
    my $port = $solr->{'port'} ||= 8080;
    my $solr_root = $self->app->solr_root;
    my $solr_dir = $self->path('solr');
    if (defined $solr->{'local'}) {
        $solr_dir = $solr->{'local'};
    }
    elsif (-l "$idir/solr") {
        $solr_dir = readlink("$idir/solr") or die "readlink $idir/solr: $!";
    }
    elsif (defined $solr_root) {
        ($solr_dir) = grep { -d } map { "$solr_root/$_" } $id, $port;
    }
    $solr->{'local'} ||= $solr_dir if defined $solr_dir;
    $solr->{'root'} ||= $self->solr_root;
    $solr->{'uri'} ||= "http://${host}:${port}/solr";
    my $cores = $solr->{'cores'} ||= {};
    foreach (qw(authority biblio reserves website)) {
        $cores->{$_} ||= $_;
    }
    return $self->{'solr'} = $solr;
}

sub build {
    my ($self, %arg) = @_;
    my $t0 = time;
    my $name = "vufind.$t0.$$";
    my $broot = $self->path('build');
    my $bdir = $self->path("build/$name");
    if (!$arg{'dry_run'}) {
        xmkdir($broot, $bdir);
    }
    my $idir = $self->path;
    my $build = $self->yml('build');
    my $sources = $build->{'sources'};
    
    my @overlays = @{ $build->{'overlays'} || [] };
    $self->build_vufind($sources->{'vufind'}, $bdir, %arg);
    $self->build_solr($sources->{'solr'}, $bdir, %arg);
    $self->apply_overlays([$self->overlays(@overlays)], $bdir, %arg);
    if (!$arg{'dry_run'}) {
        xrename($bdir, $self->path($name));
        xswapfiles($idir, $name, 'vufind');
    }
}

sub overlay {
    my ($self, $overlay) = @_;
    return $overlay if ref $overlay;
    my $dir = $overlay;
    my $name = basename($dir);
    # Read overlay.yml
    $overlay = $self->yml("$dir/overlay");
    $overlay->{'root'} = $self->dir($dir);
    # Does it use a file source?
    my $files = $self->path("$dir/files");
    $overlay->{'files'} ||= $files if -d $files;
    # Or does it use a script?
    my $script = $self->path("$dir/apply");
    $overlay->{'script'} ||= $script if -x $script && !-d _;
    # It has to be one or the other (or both)
    die "overlay $name has no files and no script"
        if !defined $overlay->{'files'} && !defined $overlay->{'script'};
    $overlay->{'name'} = $name if !defined $overlay->{'name'};
    foreach (qw(overwrite expand)) {
        $overlay->{$_} = bool($overlay->{$_});
    }
    return $overlay;
}

sub overlays {
    my ($self, @want) = @_;
    my $idir = $self->path;
    my $adir = $self->app->root;
    my @overlays;
    my %want = map { $_ => 1 } @want;
    my %seen;
    my @yml = map { glob("$_/overlay/*/overlay.yml") } ($idir, $adir);
    foreach (@yml) {
        my $odir = dirname($_);
        my $name = basename($odir);
        next if @want && !$want{$name};
        next if $seen{$name}++;
        push @overlays, $self->overlay($odir);
    }
    return @overlays;
}

sub git_status {
}

sub git_clone_and_or_checkout {
    my ($self, %arg) = @_;
    my ($clone, $repo, $dstdir, $branch) = @arg{qw(clone repo destination branch)};
    my ($srcdir, @excludes);
    if ($clone) {
        die "repo to clone from is not set" if !defined $repo;
        if (-e "$dstdir/.git") {
            # Make sure we've already cloned the correct repo into $dstdir
            my $ok;
            my $fh = run(qw(git -C), $dstdir, qw(remote -v));
            while (<$fh>) {
                next if !/^(\S+)\s+(\S+)\s+\(fetch\)$/;
                if ($repo eq $1) {
                    $repo = $2;
                    $ok = 1;
                    last;
                }
                elsif ($repo eq $2) {
                    $ok = 1;
                    last;
                }
            }
            die "no such source repo for local repo $dstdir: $repo" if !$ok;
        }
        else {
            # git clone $repo $dstdir
            run(qw(git clone), $repo, $dstdir);
        }
        if (defined $branch) {
            run(qw(git -C), $dstdir, qw(checkout), $branch);
        }
        $srcdir = $dstdir;
    }
    elsif ($repo =~ /^(git|https?):/) {
        die "you must set clone to true in the build config file";
    }
    else {
        $srcdir = $self->dir($repo);
        # Make sure the correct branch is checked out
        my @cmd = (qw(git -C), $srcdir, qw(status --porcelain=v2 --branch));
        my $fh = runcmd(@cmd);
        while (<$fh>) {
            if (/^# branch\.head (.+)/) {
                die "VuFind source repo $repo has branch $1 checked out, not $branch"
                    if $1 ne $branch;
            }
        }
        close $fh or die "finish @cmd: $!";
        push @excludes, qw(/.git);
    }
    return ($srcdir, @excludes);
}

sub build_vufind {
    my ($self, $source, $dstdir) = @_;
    my ($type, $repo, $version, $file, $exclude) = @$source{qw(type repo version file exclude)};
    $type ||= $repo ? 'git' : $version ? 'release' : die "source type not specified";
    my $srcdir;
    my @excludes = _excludes(@{ $exclude || [] });
    my %arg = ('exclude' => \@excludes);
    if ($type eq 'git') {
        ($srcdir, @excludes) = $self->git_clone_and_or_checkout(
            'clone' => bool($source->{'clone'}),
            'repo' => $repo,
            'branch' => $source->{'branch'},
            'destination' => $dstdir,
        );
    }
    elsif ($type eq 'release') {
        # Download and untar the release (as needed)
        my $extension = '.tar.gz';
        if (defined $file) {
            # $file =~ s{^file://}{};
            if ($file =~ m/^(.+)(\.tar\.[0-9A-Za-z]+)$/ or $file =~ m/^(.+)(\.tgz)$/) {
                ($srcdir, $extension) = ($1, $2);
            }
            else {
                ($srcdir, $file) = ($file, $file . $extension);
            }
        }
        elsif (defined $version) {
            $srcdir = $self->app->dir("release/vufind-$version");
            $file = $srcdir . $extension;
        }
        else {
            die "unsufficient configuration to determine VuFind source";
        }
        if (!-e $srcdir) {
            my $uri = $source->{'uri'};
            download($self->ua, $uri, $file) if !-e $file;
            untar($file, $srcdir);
        }
    }
    else {
        die "unknown instance source type: $type";
    }
    if ($dstdir ne $srcdir) {
        my @options = qw(-a);
        foreach my $x (@excludes) {
            push @options, "--exclude=$x";
        }
        runcmd('rsync', @options, "$srcdir/", "$dstdir/");
    }
}

sub apply_overlays {
    my ($self, $overlays, $dest) = @_;
    foreach (@$overlays) {
        my $overlay = $self->overlay($_);
        my ($script, $files, $overwrite, $expand, $odest) = @$overlay{qw(script files overwrite expand destination)};
        $odest = defined($odest) ? "$dest/$odest" : $dest;
        xmkdir($odest);
        if (defined $script) {
            runcmd($script, $overlay->{'root'}, $odest);
        }
        elsif (defined $files) {
            my %arg = ('source' => $files, 'destination' => $odest, 'overwrite' => bool($overwrite));
            if (bool($expand)) {
                $arg{'expando'} = expando(flatten({
                    'instance' => $self->as_hash,
                    'overlay' => $overlay,
                }));
            }
            $self->copy_files(%arg);
        }
        else {
            die "overlay $overlay->{'name'} has no script and no file source";
        }
    }
}

sub build_solr {
    my ($self, $source, $dest) = @_;
    my ($replace, $symlink) = @$source{qw(replace symlink)};
    if (bool($replace)) {
        $symlink ||= $self->solr->{'local'}
            or die "solr is not local";
        runcmd(qw(rm -Rf), "$dest/solr");
        xsymlink($symlink, "$dest/solr");
    }
    else {
        # TODO
        die "not implemented";
    }
}

sub copy_files {
    my ($self, %arg) = @_;
    my ($source, $dest, $overwrite, $exclude, $expando) = @arg{qw(source destination overwrite exclude expando)};
    if ($expando) {
        my @contents = runcmd('find', glob("$source/*"));
        chomp @contents;
        my @files;
        foreach (sort @contents) {
            my @stat = lstat($_);
            die "stat $_: $!" if !@stat;
            s{^$source/}{};
            if (-d _ && !-l _) {
                xmkdir("$dest/$_");
            }
            else {
                push @files, $_;
            }
        }
        foreach my $f (@files) {
            open my $fhin, '<', "$source/$f" or die "open < $source/$f: $!";
            open my $fhout, '>', "$dest/$f" or die "open > $dest/$f: $!";
            binmode $fhin;
            binmode $fhout;
            while (<$fhin>) {
                print $fhout $expando->expand($_);
            }
            if ($arg{'verbose'}) {
                print STDERR $f, "\n";
            }
        }
    }
    else {
        my @options = $overwrite ? qw(-a) : qw(-a --ignore-existing);
        my @excludes = _excludes(@{ $exclude || [] });
        foreach my $x (@excludes) {
            push @options, "--exclude=$x";
        }
        push @options, '-v' if $arg{'verbose'};
        runcmd('rsync', @options, "$source/", "$dest/");
    }
}

sub _excludes {
    my @excludes;
    foreach my $x (@_) {
        my $r = ref $x;
        if ($r eq '') {
            push @excludes, '/'.$x;
        }
        elsif ($r eq 'HASH') {
            my $any = delete $x->{'any'};
            die "bad exclude" if !defined $any || keys %$x;
            push @excludes, $any;
        }
        else {
            die "bad exclude";
        }
    }
    return @excludes;
}

sub build_from {
    my ($self, $dir) = @_;
    my $idir = $self->path;
    my $app = $self->app;
    my @cmd = qw(rsync -av --exclude=/local --exclude=/.git*);
    push @cmd, qw(--dry-run) if $app->dryrun;
    system(@cmd, "$dir/", "$idir/vufind/") == 0
        or die "rsync failed";
    1;
}

1;
