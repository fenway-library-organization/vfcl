package App::Vfcl::Instance;

use strict;
use warnings;

use base qw(App::Vfcl::Object);

use App::Vfcl::Util;

sub id { @_ > 1 ? $_[0]{'id'} = $_[1] : $_[0]{'id'} }
sub app { @_ > 1 ? $_[0]{'app'} = $_[1] : $_[0]{'app'} }
sub solr { @_ > 1 ? $_[0]{'solr'} = $_[1] : $_[0]{'solr'} }
sub source { @_ > 1 ? $_[0]{'source'} = $_[1] : $_[0]{'source'} }

sub directory { @_ > 1 ? $_[0]{'_directory'} = $_[1] : $_[0]{'_directory'} }
sub ua { @_ > 1 ? $_[0]{'_ua'} = $_[1] : $_[0]{'_ua'} }

sub create {
    my $cls = shift;
    my $self = ref($cls) ? $cls : $cls->new(@_);
    my $id = $self->id;
    my $app = $self->app;
    my $root = $app->root;
    foreach ($root, 'instance', $id) {
        -d $_ or mkdir $_ or die "mkdir $_: $!";
        chdir $_ or die "chdir $_: $!";
    }
    $app->kvwrite('instance.kv', $self->as_kv);
    #kvwrite('solr.kv', $solr);
    #kvwrite('source.kv', $vufind);

}

sub build {
    my ($self) = @_;
    my $idir = $self->directory;
    my $source = $self->source;
    my ($vufind, $local) = @$source{qw(vufind local)};
    my ($vtype, $vrepo, $vbranch, $vversion, $vfile) = @$vufind{qw(type repo branch version file)};
    my ($ltype, $lrepo, $lbranch, $ldir) = @$local{qw(type repo branch dir)};
    $vtype ||= $vrepo ? 'git' : $vversion ? 'release' : die "source type not specified";
    my $vdir;
    if ($vtype eq 'git') {
        # Check out the git branch
        if ($vrepo =~ m{^/}) {
            $vdir = $vrepo;
        }
        elsif ($vrepo =~ /^(git|https?):/) {
            die "remote repositories are not supported";
        }
        else {
            $vdir = canonpath($vrepo, $idir);
        }
        checkout($vbranch, $vdir);
    }
    elsif ($vtype eq 'release') {
        # Download and untar the release (as needed)
        my $extension = '.tar.gz';
        if (defined $vfile) {
            # $file =~ s{^file://}{};
            if ($vfile =~ m/^(.+)(\.tar\.[0-9A-Za-z]+)$/ or $vfile =~ m/^(.+)(\.tgz)$/) {
                ($vdir, $extension) = ($1, $2);
            }
            else {
                ($vdir, $vfile) = ($vfile, $vfile . $extension);
            }
        }
        elsif (defined $vversion) {
            $vdir = "$idir/release/vufind-$vversion";
            $vfile = $vdir . $extension;
        }
        else {
            die "unsufficient configuration to determine VuFind source";
        }
        if (!-e $vdir) {
            my $uri = $vufind->{'uri'};
            download($self->ua, $uri, $vfile) if !-e $vfile;
            untar($vfile, $vdir);
        }
    }
    else {
        die "unknown instance source type: $vtype";
    }
    # Copy files, etc.
    $self->build_from($vdir);
}

sub build_from {
    my ($self, $dir) = @_;
    my $idir = $self->directory;
    my $app = $self->app;
    my @cmd = qw(rsync -av --exclude=/local);
    push @cmd, qw(--dry-run) if $app->dryrun;
    system(@cmd, "$dir/", "$idir/vufind/") == 0
        or die "rsync failed";
    1;
}

1;
