package App::Vfcl::Util;

# Utility routines

sub download {
    my ($ua, $uri, $file) = @_;
    my $res = $ua->get($uri, ':content_file' => $file);
    my $msg = $res->header('Client-Aborted');
    if (!$res->is_success || defined $msg) {
        my $err = $msg || $res->status_line;
        die "download $uri to $file: $err";
    }
}

sub untar {
    my ($tarball, $destdir) = @_;
    my @cmd = qw(tar);
    push @cmd, ('-C' => $destdir) if !defined $destdir || $destdir ne '.';
    push @cmd, ('-x', '-v');
    push @cmd, ('-z') if $tarball =~ /\.t(?:ar\.)?gz$/;
    push @cmd, ('-f' => $tarball);
    system(@cmd) == 0
        or die "@cmd failed";
}

sub checkout {
    my ($branch, $gitdir) = @_;
    my @cmd = qw(git);
    push @cmd, ('-C' => $gitdir) if !defined $gitdir || $gitdir ne '.';
    push @cmd, ('checkout', $branch);
    system(@cmd) == 0
        or die "@cmd failed\n";
}

1;
