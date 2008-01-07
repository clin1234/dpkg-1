#!/usr/bin/perl

use strict;
use warnings;

use POSIX;
use POSIX qw(:errno_h :signal_h);
use English;
use Dpkg;
use Dpkg::Gettext;
use Dpkg::ErrorHandling qw(warning error failure unknown internerr syserr
                           subprocerr usageerr);
use Dpkg::Arch qw(get_host_arch debarch_eq debarch_is);
use Dpkg::Fields qw(capit set_field_importance sort_field_by_importance);
use Dpkg::Compression;

push(@INC,$dpkglibdir);
require 'controllib.pl';

our (%f, %fi);
our %p2i;
our %substvar;
our $sourcepackage;

textdomain("dpkg-dev");

my @changes_fields = qw(Format Date Source Binary Architecture Version
                        Distribution Urgency Maintainer Changed-By
                        Description Closes Changes Files);

my $controlfile = 'debian/control';
my $changelogfile = 'debian/changelog';
my $changelogformat;
my $fileslistfile = 'debian/files';
my $varlistfile = 'debian/substvars';
my $uploadfilesdir = '..';
my $sourcestyle = 'i';
my $quiet = 0;

my %f2p;           # - file to package map
my %p2f;           # - package to file map, has entries for "packagename"
my %pa2f;          # - likewise, has entries for "packagename architecture"
my %p2ver;         # - package to version map
my %p2arch;        # - package to arch map
my %f2sec;         # - file to section map
my %f2seccf;       # - likewise, from control file
my %f2pri;         # - file to priority map
my %f2pricf;       # - likewise, from control file
my %sourcedefault; # - default values as taken from source (used for Section,
                   #   Priority and Maintainer)

my @descriptions;
my @sourcefiles;
my @fileslistfiles;

my %md5sum;        # - md5sum to file map
my %remove;        # - fields to remove
my %override;
my %archadded;
my @archvalues;
my $dsc;
my $changesdescription;
my $forcemaint;
my $forcechangedby;
my $since;

use constant SOURCE     => 1;
use constant ARCH_DEP   => 2;
use constant ARCH_INDEP => 4;
use constant BIN        => ARCH_DEP | ARCH_INDEP;
use constant ALL        => BIN | SOURCE;
my $include = ALL;

sub is_sourceonly() { return $include == SOURCE; }
sub is_binaryonly() { return !($include & SOURCE); }
sub binary_opt() { return (($include == BIN) ? '-b' :
			   (($include == ARCH_DEP) ? '-B' :
			    (($include == ARCH_INDEP) ? '-A' :
			     internerr("binary_opt called with include=$include"))));
}

sub version {
    printf _g("Debian %s version %s.\n"), $progname, $version;

    printf _g("
Copyright (C) 1996 Ian Jackson.
Copyright (C) 2000,2001 Wichert Akkerman.");

    printf _g("
This is free software; see the GNU General Public Licence version 2 or
later for copying conditions. There is NO warranty.
");
}

sub usage {
    printf _g(
"Usage: %s [<option> ...]

Options:
  -b                       binary-only build - no source files.
  -B                       arch-specific - no source or arch-indep files.
  -A                       only arch-indep - no source or arch-specific files.
  -S                       source-only upload.
  -c<controlfile>          get control info from this file.
  -l<changelogfile>        get per-version info from this file.
  -f<fileslistfile>        get .deb files list from this file.
  -v<sinceversion>         include all changes later than version.
  -C<changesdescription>   use change description from this file.
  -m<maintainer>           override control's maintainer value.
  -e<maintainer>           override changelog's maintainer value.
  -u<uploadfilesdir>       directory with files (default is \`..').
  -si (default)            src includes orig for debian-revision 0 or 1.
  -sa                      source includes orig src.
  -sd                      source is diff and .dsc only.
  -q                       quiet - no informational messages on stderr.
  -F<changelogformat>      force change log format.
  -V<name>=<value>         set a substitution variable.
  -T<varlistfile>          read variables here, not debian/substvars.
  -D<field>=<value>        override or add a field and value.
  -U<field>                remove a field.
  -h, --help               show this help message.
      --version            show the version.
"), $progname;
}


while (@ARGV) {
    $_=shift(@ARGV);
    if (m/^-b$/) {
	is_sourceonly && &usageerr(_g("cannot combine %s and -S"), $_);
	$include = BIN;
    } elsif (m/^-B$/) {
	is_sourceonly && &usageerr(_g("cannot combine %s and -S"), $_);
	$include = ARCH_DEP;
	printf STDERR _g("%s: arch-specific upload - not including arch-independent packages")."\n", $progname;
    } elsif (m/^-A$/) {
	is_sourceonly && &usageerr(_g("cannot combine %s and -S"), $_);
	$include = ARCH_INDEP;
	printf STDERR _g("%s: arch-indep upload - not including arch-specific packages")."\n", $progname;
    } elsif (m/^-S$/) {
	is_binaryonly && &usageerr(_g("cannot combine %s and -S"), binary_opt);
	$include = SOURCE;
    } elsif (m/^-s([iad])$/) {
        $sourcestyle= $1;
    } elsif (m/^-q$/) {
        $quiet= 1;
    } elsif (m/^-c/) {
	$controlfile= $POSTMATCH;
    } elsif (m/^-l/) {
	$changelogfile= $POSTMATCH;
    } elsif (m/^-C/) {
	$changesdescription= $POSTMATCH;
    } elsif (m/^-f/) {
	$fileslistfile= $POSTMATCH;
    } elsif (m/^-v/) {
	$since= $POSTMATCH;
    } elsif (m/^-T/) {
	$varlistfile= $POSTMATCH;
    } elsif (m/^-m/) {
	$forcemaint= $POSTMATCH;
    } elsif (m/^-e/) {
	$forcechangedby= $POSTMATCH;
    } elsif (m/^-F([0-9a-z]+)$/) {
        $changelogformat=$1;
    } elsif (m/^-D([^\=:]+)[=:]/) {
	$override{$1}= $POSTMATCH;
    } elsif (m/^-u/) {
	$uploadfilesdir= $POSTMATCH;
    } elsif (m/^-U([^\=:]+)$/) {
        $remove{$1}= 1;
    } elsif (m/^-V(\w[-:0-9A-Za-z]*)[=:]/) {
	$substvar{$1}= $POSTMATCH;
    } elsif (m/^-(h|-help)$/) {
        &usage; exit(0);
    } elsif (m/^--version$/) {
        &version; exit(0);
    } else {
        usageerr(_g("unknown option \`%s'"), $_);
    }
}

parsechangelog($changelogfile, $changelogformat, $since);
parsecontrolfile($controlfile);

if (not is_sourceonly) {
    open(FL,"<",$fileslistfile) || &syserr(_g("cannot read files list file"));
    while(<FL>) {
	if (m/^(([-+.0-9a-z]+)_([^_]+)_([-\w]+)\.u?deb) (\S+) (\S+)$/) {
	    defined($p2f{"$2 $4"}) &&
		warning(_g("duplicate files list entry for package %s (line %d)"),
			$2, $NR);
	    $f2p{$1}= $2;
	    $pa2f{"$2 $4"}= $1;
	    $p2f{$2} ||= [];
	    push @{$p2f{$2}}, $1;
	    $p2ver{$2}= $3;
	    defined($f2sec{$1}) &&
		warning(_g("duplicate files list entry for file %s (line %d)"),
			$1, $NR);
	    $f2sec{$1}= $5;
	    $f2pri{$1}= $6;
	    push(@archvalues,$4) unless !$4 || $archadded{$4}++;
	    push(@fileslistfiles,$1);
	} elsif (m/^([-+.0-9a-z]+_[^_]+_([-\w]+)\.[a-z0-9.]+) (\S+) (\S+)$/) {
	    # A non-deb package
	    $f2sec{$1}= $3;
	    $f2pri{$1}= $4;
	    push(@archvalues,$2) unless !$2 || $archadded{$2}++;
	    push(@fileslistfiles,$1);
	} elsif (m/^([-+.,_0-9a-zA-Z]+) (\S+) (\S+)$/) {
	    defined($f2sec{$1}) &&
		warning(_g("duplicate files list entry for file %s (line %d)"),
			$1, $NR);
	    $f2sec{$1}= $2;
	    $f2pri{$1}= $3;
	    push(@fileslistfiles,$1);
	} else {
	    error(_g("badly formed line in files list file, line %d"), $NR);
	}
    }
    close(FL);
}

for $_ (keys %fi) {
    my $v = $fi{$_};

    if (s/^C //) {
	if (m/^Source$/) {
	    setsourcepackage($v);
	}
	elsif (m/^Section$|^Priority$/i) { $sourcedefault{$_}= $v; }
	elsif (m/^Maintainer$/i) { $f{$_}= $v; }
	elsif (s/^X[BS]*C[BS]*-//i) { $f{$_}= $v; }
	elsif (m/^X[BS]+-/i ||
	       m/^Build-(Depends|Conflicts)(-Indep)?$/i ||
	       m/^(Standards-Version|Uploaders|Homepage|Origin|Bugs)$/i ||
	       m/^Vcs-(Browser|Arch|Bzr|Cvs|Darcs|Git|Hg|Mtn|Svn)$/i) {
	}
	else { &unknown(_g('general section of control info file')); }
    } elsif (s/^C(\d+) //) {
	my $i = $1;
	my $p = $fi{"C$i Package"};
	my $a = $fi{"C$i Architecture"};
	my $host_arch = get_host_arch();

	if (!defined($p2f{$p}) && not is_sourceonly) {
	    if ((debarch_eq('all', $a) and ($include & ARCH_INDEP)) ||
		(grep(debarch_is($host_arch, $_), split(/\s+/, $a))
		      and ($include & ARCH_DEP))) {
		warning(_g("package %s in control file but not in files list"),
		        $p);
		next;
	    }
	} else {
	    my @f;
	    @f = @{$p2f{$p}} if defined($p2f{$p});
	    $p2arch{$p}=$a;

	    if (m/^Description$/) {
		$v=$PREMATCH if $v =~ m/\n/;
		my %d;
		# dummy file to get each description at least once (e.g. -S)
		foreach my $f (("", @f)) {
		    my $desc = sprintf("%-10s - %-.65s%s", $p, $v,
				       $f =~ m/\.udeb$/ ? " (udeb)" : '');
		    $d{$desc}++;
		}
		push @descriptions, keys %d;
	    } elsif (m/^Section$/) {
		$f2seccf{$_} = $v foreach (@f);
	    } elsif (m/^Priority$/) {
		$f2pricf{$_} = $v foreach (@f);
	    } elsif (s/^X[BS]*C[BS]*-//i) {
		$f{$_}= $v;
	    } elsif (m/^Architecture$/) {
		if (not is_sourceonly) {
		    if (grep(debarch_is($host_arch, $_), split(/\s+/, $v))
			and ($include & ARCH_DEP)) {
			$v = $host_arch;
		    } elsif (!debarch_eq('all', $v)) {
			$v= '';
		    }
		} else {
		    $v = '';
		}
		push(@archvalues,$v) unless !$v || $archadded{$v}++;
	    } elsif (m/^(Package|Package-Type|Kernel-Version|Essential)$/ ||
	             m/^(Homepage|Tag|Installer-Menu-Item|Subarchitecture)$/i ||
	             m/^(Pre-Depends|Depends|Recommends|Suggests|Provides)$/ ||
	             m/^(Enhances|Conflicts|Breaks|Replaces)$/ ||
		     m/^X[BS]+-/i) {
	    } else {
		&unknown(_g("package's section of control info file"));
	    }
	}
    } elsif (s/^L //) {
        if (m/^Source$/i) {
	    setsourcepackage($v);
        } elsif (m/^Maintainer$/i) {
	    $f{"Changed-By"}=$v;
        } elsif (m/^(Version|Changes|Urgency|Distribution|Date|Closes)$/i) {
            $f{$_}= $v;
        } elsif (s/^X[BS]*C[BS]*-//i) {
            $f{$_}= $v;
        } elsif (!m/^X[BS]+-/i) {
            &unknown(_g("parsed version of changelog"));
        }
    } elsif (m/^o:.*/) {
    } else {
	internerr("value from nowhere, with key >%s< and value >%s<",
                  $_, $v);
    }
}

if ($changesdescription) {
    $f{'Changes'}= '';
    open(X,"<",$changesdescription) || &syserr(_g("read changesdescription"));
    while(<X>) {
        s/\s*\n$//;
        $_= '.' unless m/\S/;
        $f{'Changes'}.= "\n $_";
    }
}

for my $pa (keys %pa2f) {
    my ($pp, $aa) = (split / /, $pa);
    defined($p2i{"C $pp"}) ||
	warning(_g("package %s listed in files list but not in control info"),
	        $pp);
}

for my $p (keys %p2f) {
    my @f = @{$p2f{$p}};

    foreach my $f (@f) {
	my $sec = $f2seccf{$f};
	$sec ||= $sourcedefault{'Section'};
	if (!defined($sec)) {
	    $sec = '-';
	    warning(_g("missing Section for binary package %s; using '-'"), $p);
	}
	$sec eq $f2sec{$f} || error(_g("package %s has section %s in " .
				       "control file but %s in files list"),
				    $p, $sec, $f2sec{$f});
	my $pri = $f2pricf{$f};
	$pri ||= $sourcedefault{'Priority'};
	if (!defined($pri)) {
	    $pri = '-';
	    warning(_g("missing Priority for binary package %s; using '-'"), $p);
	}
	$pri eq $f2pri{$f} || error(_g("package %s has priority %s in " .
				       "control file but %s in files list"),
				    $p, $pri, $f2pri{$f});
    }
}

&init_substvars;
init_substvar_arch();

my $origsrcmsg;

if (!is_binaryonly) {
    my $sec = $sourcedefault{'Section'};
    if (!defined($sec)) {
	$sec = '-';
	warning(_g("missing Section for source files"));
    }
    my $pri = $sourcedefault{'Priority'};
    if (!defined($pri)) {
	$pri = '-';
	warning(_g("missing Priority for source files"));
    }

    (my $sversion = $substvar{'source:Version'}) =~ s/^\d+://;
    $dsc= "$uploadfilesdir/${sourcepackage}_${sversion}.dsc";
    open(CDATA, "<", $dsc) || syserr(_g("cannot open .dsc file %s"), $dsc);
    push(@sourcefiles,"${sourcepackage}_${sversion}.dsc");

    parsecdata(\*CDATA, 'S', -1, sprintf(_g("source control file %s"), $dsc));

    my $files = $fi{'S Files'};
    for my $file (split(/\n /, $files)) {
        next if $file eq '';
        $file =~ m/^([0-9a-f]{32})[ \t]+\d+[ \t]+([0-9a-zA-Z][-+:.,=0-9a-zA-Z_~]+)$/
            || error(_g("Files field contains bad line \`%s'"), $file);
        ($md5sum{$2},$file) = ($1,$2);
        push(@sourcefiles,$file);
    }
    for my $f (@sourcefiles) {
	$f2sec{$f} = $sec;
	$f2pri{$f} = $pri;
    }

    if (($sourcestyle =~ m/i/ && $sversion !~ m/-(0|1|0\.1)$/ ||
	 $sourcestyle =~ m/d/) &&
	grep(m/\.diff\.$comp_regex$/,@sourcefiles)) {
	$origsrcmsg= _g("not including original source code in upload");
	@sourcefiles= grep(!m/\.orig\.tar\.$comp_regex$/,@sourcefiles);
    } else {
	if ($sourcestyle =~ m/d/ &&
	    !grep(m/\.diff\.$comp_regex$/,@sourcefiles)) {
	    warning(_g("ignoring -sd option for native Debian package"));
	}
        $origsrcmsg= _g("including full source code in upload");
    }
} else {
    $origsrcmsg= _g("binary-only upload - not including any source code");
}

print(STDERR "$progname: $origsrcmsg\n") ||
    &syserr(_g("write original source message")) unless $quiet;

$f{'Format'}= $substvar{'Format'};

if (!defined($f{'Date'})) {
    chomp(my $date822 = `date -R`);
    $? && subprocerr("date -R");
    $f{'Date'}= $date822;
}

$f{'Binary'}= join(' ',grep(s/C //,keys %p2i));

unshift(@archvalues,'source') unless is_binaryonly;
@archvalues = ('all') if $include == ARCH_INDEP;
@archvalues = grep {!debarch_eq('all',$_)} @archvalues
    unless $include & ARCH_INDEP;
$f{'Architecture'}= join(' ',@archvalues);

$f{'Description'}= "\n ".join("\n ",sort @descriptions);

$f{'Files'}= '';

my %filedone;

for my $f (@sourcefiles, @fileslistfiles) {
    next if ($include == ARCH_DEP and debarch_eq('all', $p2arch{$f2p{$f}}));
    next if ($include == ARCH_INDEP and not debarch_eq('all', $p2arch{$f2p{$f}}));
    next if $filedone{$f}++;
    my $uf = "$uploadfilesdir/$f";
    open(STDIN, "<", $uf) ||
	syserr(_g("cannot open upload file %s for reading"), $uf);
    (my @s = stat(STDIN)) || syserr(_g("cannot fstat upload file %s"), $uf);
    my $size = $s[7];
    $size || warning(_g("upload file %s is empty"), $uf);
    my $md5sum = `md5sum`;
    $? && subprocerr(_g("md5sum upload file %s"), $uf);
    $md5sum =~ m/^([0-9a-f]{32})\s*-?\s*$/i ||
        failure(_g("md5sum upload file %s gave strange output \`%s'"),
                $uf, $md5sum);
    $md5sum= $1;
    defined($md5sum{$f}) && $md5sum{$f} ne $md5sum &&
        error(_g("md5sum of source file %s (%s) is different from md5sum " .
                 "in %s (%s)"), $uf, $md5sum, $dsc, $md5sum{$f});
    $f{'Files'}.= "\n $md5sum $size $f2sec{$f} $f2pri{$f} $f";
}

$f{'Source'}= $sourcepackage;
if ($f{'Version'} ne $substvar{'source:Version'}) {
    $f{'Source'} .= " ($substvar{'source:Version'})";
}

$f{'Maintainer'} = $forcemaint if defined($forcemaint);
$f{'Changed-By'} = $forcechangedby if defined($forcechangedby);

for my $f (qw(Version Distribution Maintainer Changes)) {
    defined($f{$f}) ||
        error(_g("missing information for critical output field %s"), $f);
}

for my $f (qw(Urgency)) {
    defined($f{$f}) ||
        warning(_g("missing information for output field %s"), $f);
}

for my $f (keys %override) {
    $f{capit($f)} = $override{$f};
}
for my $f (keys %remove) {
    delete $f{capit($f)};
}

set_field_importance(@changes_fields);
outputclose();

