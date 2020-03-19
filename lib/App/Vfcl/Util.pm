package App::Vfcl::Util;

use strict;
use warnings;

use File::Basename qw(basename);

### use vars qw(@ISA @EXPORT @EXPORT_OK);
### 
### require Exporter;
### @ISA = qw(Exporter);
### @EXPORT = qw(
###     usage fatal
###     download untar checkout canonpath
###     kvmake kvread kvwrite
###     oread owrite oreadwrite
### );
### @EXPORT_OK = ();

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

sub canonpath {
    shift;
    return if !defined $_[0];
    return realpath(File::Spec->rel2abs(@_));
}

sub kvmake {
    my ($hash) = @_;
    my %kv = map { $_ => $hash->{$_} } grep { !/^_/ } keys %$hash;
    return flatten(\%kv);
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
            die "unparseable: config file $f line $.: $_";
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

sub oread {
    my ($file) = @_;
    open my $fh, '<', $file or fatal("open $file for reading: $!");
    return $fh;
}

sub owrite {
    my ($file) = @_;
    open my $fh, '>', $file or fatal("open $file for writing: $!");
    return $fh;
}

sub oreadwrite {
    my ($file) = @_;
    open my $fh, '+<', $file or fatal("open $file for reading and writing: $!");
    return $fh;
}

sub xmkdir {
    foreach my $dir (@_) {
        -d $dir or mkdir $dir or fatal("mkdir $dir: $!");
    }
}

sub xmove {
    my $d = pop;
    foreach my $s (@_) {
        move($s, $d)
            or fatal("move $s $d: $!");
    }
}

sub xrename {
    my ($s, $d) = @_;
    rename $s, $d or fatal("rename $s to $d: $!");
}

sub xchdir {
    foreach my $dir (@_) {
        chdir $dir or fatal("chdir $dir: $!");
    }
}

sub usage {
    my $prog = basename($0);
    print STDERR "usage: $prog COMMAND [ARG...]\n";
    exit 1;
}

sub fatal {
    print STDERR basename($0), ': ', @_, "\n";
    exit 2;
}

1;
