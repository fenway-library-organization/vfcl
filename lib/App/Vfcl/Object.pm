package App::Vfcl::Object;

use strict;
use warnings;

use App::Vfcl::Util;
use File::Basename qw(dirname);
use Hash::Flatten qw(:all);

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub root { @_ > 1 ? $_[0]{'root'} = $_[1] : $_[0]{'root'} }

sub _private_members {
    my ($self) = @_;
    return 'root', grep { /(?:^|\.)_/ || ref($self->{$_}) =~ /::/ } keys %$self;
}

sub type {
    my ($cls_or_obj) = @_;
    my $ref = ref($cls_or_obj) || $cls_or_obj;
    $ref =~ s/.+:://;                   # Foo::Bar::CamelCaseWord -> CamelCaseWord
    $ref =~ s/(?<=[a-z])(?=[A-Z])/_/g;  # CamelCaseWord -> Camel_case_word
    return lc $ref;                     # Camel_case_word -> camel_case_word
}

sub path {
    my ($self, $f) = @_;
    my $root = $self->root;
    return $root if !defined $f;
    return canonpath($f, $root);
}

sub file {
    my ($self, $f) = @_;
    $f = canonpath($f, $self->root);
    die "no such file: $f" if !-f $f;
    return $f;
}

sub dir {
    my ($self, $f) = @_;
    $f = canonpath($f, $self->root);
    die "no such directory: $f" if !-d $f;
    return $f;
}

sub create_with_file {
    my ($self, $f) = @_;
    $f ||= $self->path($self->type . '.yml');
    xmkpath(dirname($f));
    ymlwrite($f, $self->as_hash);
    return $self;
}

sub init_from_file {
    my ($self, $f) = @_;
    $f ||= $self->file($self->type . '.yml');
    my $serialized = ymlread($f);
    %$self = (
        %$serialized,
        %$self,
    );
}

sub as_hash {
    my ($self) = @_;
    my %serialize = %$self;
    my @private = $self->_private_members;
    delete @serialize{@private} if @private;
    return \%serialize;
    ### return flatten(\%serialize);
}

1;
