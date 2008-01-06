# -*- mode: cperl;-*-

use Test::More tests => 6;

use strict;
use warnings;

use_ok('Dpkg::BuildOptions');

$ENV{DEB_BUILD_OPTIONS} = 'foonostripbar,parallel=3,bazNOCHECK';

my $dbo = Dpkg::BuildOptions::parse();

my %dbo = (
	   nostrip => '',
	   nocheck => '',
	   parallel => 3,
	   );
my %dbo2 = (
	    nocheck => '',
	   );


is_deeply($dbo, \%dbo, 'parse');

$dbo = Dpkg::BuildOptions::parse('no opt,no-strip,parallel = 5,nocheck');

is_deeply($dbo, \%dbo2, 'parse (param)');

$dbo->{parallel} = 5;
$dbo->{noopt} = '';

my $env = Dpkg::BuildOptions::set($dbo,1);

is($ENV{DEB_BUILD_OPTIONS}, $env, 'set (return value)');
is_deeply(Dpkg::BuildOptions::parse(), $dbo, 'set (env)');

$ENV{DEB_BUILD_OPTIONS} = 'foobar';
$dbo = { noopt => '' };
$env = Dpkg::BuildOptions::set($dbo, 0);
is($env, "foobar,noopt,", 'set (append)');
