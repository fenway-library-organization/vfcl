use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
    module_name => 'vfcl',
    dist_abstract => 'manage multiple VuFind instances',
    dist_author => 'Paul Hoffman (paul AT flo DOT org)',
    dist_version_from => 'lib/App/Vfcl.pm',
    requires => {
        'Cwd' => 0,
        'Fcntl' => 0,
        'File::Basename' => 0,
        'File::Copy' => 0,
        'File::Spec' => 0,
        'FindBin' => 0,
        'Getopt::Long' => 0,
        'Hash::Flatten' => 0,
        'JSON' => 0,
        'LWP::UserAgent' => 0,
        'MARC::Loop' => 0,
        'POSIX' => 0,
        'Try::Tiny' => 0,
    },
    configure_requires => {
        'Module::Build' => 0.42,
    },
    build_requires => {
    },
    license => 'perl_5',
    create_readme => 1,
    create_makefile_pl => 'traditional',
);

$build->create_build_script;


