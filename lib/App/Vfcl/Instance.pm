package App::Vfcl::Instance;

use base qw(App::Vfcl::Object);

App::Vfcl::Util->gimme;

sub id { @_ > 1 ? $_[0]{'id'} = $_[1] : $_[0]{'id'} }
sub solr { @_ > 1 ? $_[0]{'solr'} = $_[1] : $_[0]{'solr'} }
sub source { @_ > 1 ? $_[0]{'source'} = $_[1] : $_[0]{'source'} }

sub directory { @_ > 1 ? $_[0]{'_directory'} = $_[1] : $_[0]{'_directory'} }
sub ua { @_ > 1 ? $_[0]{'_ua'} = $_[1] : $_[0]{'_ua'} }

sub create {
    my $cls = shift;
    my $self = ref($cls) ? $cls : $cls->new(@_);
    my $id = $self->id;
    foreach ($root, 'instance', $id) {
        main::xmkdir($_);
        main::xchdir($_);
    }
    main::kvwrite('instance.kv', $self->as_kv);
    #kvwrite('solr.kv', $solr);
    #kvwrite('source.kv', $vufind);

}

sub build {
    my ($self) = @_;
    my $idir = $self->directory;
    my $source = $self->source;
    my ($type, $repo, $branch, $version, $file) = @$source{qw(type repo branch version file)};
    $type ||= $repo ? 'git' : $version ? 'release' : die "source type not specified";
    my $dir;
    if ($type eq 'git') {
        # Check out the git branch
        if ($repo =~ m{^/}) {
            $dir = $repo;
        }
        elsif ($repo =~ /^(git|https?):/) {
            die "remote repositories are not supported";
        }
        else {
            $dir = canonpath($repo, $idir);
        }
        checkout($branch, $dir);
    }
    elsif ($type eq 'release') {
        # Download and untar the release (as needed)
        my $extension = '.tar.gz';
        if (defined $file) {
            # $file =~ s{^file://}{};
            if ($file =~ m/^(.+)(\.tar\.[0-9A-Za-z]+)$/ or $file =~ m/^(.+)(\.tgz)$/) {
                ($dir, $extension) = ($1, $2);
            }
            else {
                ($dir, $file) = ($file, $file . $extension);
            }
        }
        elsif (defined $version) {
            $dir = "$idir/release/vufind-$version";
            $file = $dir . $extension;
        }
        else {
            die "unsufficient configuration to determine VuFind source";
        }
        if (!-e $dir) {
            my $uri = $source->{'uri'};
            download($self->ua, $uri, $file) if !-e $file;
            untar($file, $dir);
        }
    }
    else {
        die "unknown instance source type: $type";
    }
    # Copy files, etc.
    $self->build_from($dir);
}

sub build_from {
    my ($self, $dir) = @_;
    my $idir = $self->directory;
    my @cmd = qw(rsync -av --exclude=/local);
    push @cmd, qw(--dry-run) if $dryrun;
    system(@cmd, "$dir/", "$idir/vufind/") == 0
        or die "rsync failed";
    1;
}

1;
