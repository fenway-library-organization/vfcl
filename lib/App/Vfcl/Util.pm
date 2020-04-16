package App::Vfcl::Util;

use strict;
use warnings;

use File::Spec;
use File::Basename qw(basename dirname);
use Cwd qw(realpath);
use POSIX qw(strftime);
use YAML qw();
use Hash::Flatten qw(flatten);
use String::Expando;

use vars qw(@ISA @EXPORT @EXPORT_OK);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
    basename
    bool
    canonpath
    checkout
    dirname
    download
    expando
    fatal
    flatten
    opt
    oread
    oreadwrite
    owrite
    runcmd
    strftime
    untar
    usage
    xchdir
    xmkdir
    xmove
    xrename
    xswapfiles
    xsymlink
    ymlmake
    ymlread
    ymlwrite
);
@EXPORT_OK = ();

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
    push @cmd, ('-C' => $gitdir) if defined $gitdir && $gitdir ne '.';
    runcmd(@cmd, 'checkout', $branch);
}

sub runcmd {
    my $w = wantarray;
    if (!defined $w) {
        # No return value wanted
        system(@_) == 0
            or die "exec @_: $!";
        return;
    }
    open my $fh, '-|', @_
        or die "exec @_: $!";
    return $fh if !$w;
    my @output = <$fh>;
    close $fh or die "exit value of @_: ", $? >> 8;
    return @output;
}

sub canonpath {
    return if !defined $_[0];
    return realpath(File::Spec->rel2abs(@_));
}

sub ymlmake {
    my ($hash) = @_;
    return $hash;
    ### my %kv = map { $_ => $hash->{$_} } grep { !/^_/ } keys %$hash;
    ### return flatten(\%kv);
}

sub ymlread {
    my ($f) = @_;
    return YAML::LoadFile($f);
    ### my $fh = oread($f);
    ### my %kv;
    ### while (<$fh>) {
    ###     next if /^\s*(?:#.*)?$/;  # Skip blank lines and comments
    ###     if (/^(\S+)\s+(.*)$/) {
    ###         my ($k, $v) = ($1, $2);
    ###         my $hash = \%kv;
    ###         while ($k =~ s/^([^.]+)\.//) {
    ###             $hash = $hash->{$1} ||= {};
    ###         }
    ###         $hash->{$k} = $v;
    ###     }
    ###     else {
    ###         chomp;
    ###         die "unparseable: config file $f line $.: $_";
    ###     }
    ### }
    ### return \%kv;
}

sub ymlwrite {
    my $f = shift;
    return YAML::DumpFile($f, ymlmake(shift));
    ### my $kv = kvmake(shift);
    ### my $fh = owrite($f);
    ### foreach my $k (sort keys %$kv) {
    ###     my $v = $kv->{$k};
    ###     printf $fh "%s %s\n", $k, $v if defined $v;
    ### }
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

sub xmkpath {
    my ($dir) = @_;
    my @dirs;
    while ($dir ne '/' && !-d $dir) {
        unshift @dirs, $dir;
        $dir = dirname($dir);
    }
    xmkdir(@dirs);
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

sub xswapfiles {
    my ($dir, $oldname, $newname) = @_;
    my ($old, $new) = map { "$dir/$_" } ($oldname, $newname);
    my $n = 1;
    my $err;
    while ($n++ <= 100) {
        my $tmp = $dir . '/.tmp.' . $n . '.' . $newname;  # e.g., /path/to/.tmp.1.example.yml
        if (rename $new, $tmp) {
            if (rename $old, $new) {
                return if rename $tmp, $old;
            }
            else {
                rename $tmp, $new;
            }
            $err = $!;
            last;
        }
        else {
            $err = $!;
        }
    }
    die "swap files $old <=> $new: $err";
}

sub xsymlink {
    my ($oldf, $newf) = @_;
    symlink $oldf, $newf or die "symlink @_: $!";
}

sub expando {
    unshift @_, 'stash' if @_ % 2;
    return String::Expando->new(
        # These parameters work around bugs in String::Expando 0.05 (and earlier):
        # (1) Expanding a string that contains "\n" always fails.
        'literal' => qr/(.|[\x0a\x0d])/,
        # (2) Strings like "50% of it (approximately)..." generate specious warnings.
        #     See String::Expando::init to understand why ((...)) instead of just (...).
        'expando' => '[%][(](([^\s()]+))[)]',
        @_,
    );
}

sub bool {
    my ($str, %arg) = @_;
    # bool($str);
    # bool($str, 'strict' => 1);
    # bool($str, 'default' => $val);
    return 0 if !defined $str;
    return 1 if $str =~ /^(true|yes|on|1)$/i;
    return 0 if $str =~ /^(false|no|off|0)$/i;
    die "invalid boolean: $str" if $arg{'strict'};
    return $arg{'default'} || 0;
}

sub opt {
    return defined $_[1] ? (@_) : ();
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
