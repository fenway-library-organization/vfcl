package App::Vfcl::Object;

use strict;
use warnings;

sub new {
    my $cls = shift;
    bless { @_ }, $cls;
}

sub as_kv {
    my ($self) = @_;
    my $hash = main::flatten($self);
    my @private = grep { /(?:^|\.)_/ } keys %$hash;
    delete @$hash{@private};
    return $hash;
}

1;
