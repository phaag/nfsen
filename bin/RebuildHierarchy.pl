#!%%PERL%% -w
#
#
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#     this list of conditions and the following disclaimer in the documentation
#     and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#     used to endorse or promote products derived from this software without
#     specific prior written permission.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
#  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
#  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
#  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
#  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
#  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
#  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
#  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
#  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
#  POSSIBILITY OF SUCH DAMAGE.
#
#  $Author: peter $
#
#  $Id: RebuildHierarchy.pl 27 2011-12-29 12:53:29Z peter $
#
#  $LastChangedRevision: 27 $

require 5.6.0;


use strict;
use File::Find;
use POSIX qw(strftime);
use Time::Local;

######################################
#
# Configuration: 
# The only parameter to set:

use lib "%%LIBEXECDIR%%";

#
######################################

use NfSen;
use NfProfile;
use NfSenRC;

my $profiledir;
my $source;
my ($uid, $gid);

sub ValidISO {
    my $time = shift;

    # strinp '-' chars
    $time =~ s/\-//g;

    # any non - number char is invalid
    return 0 if $time =~ /[^\d]+/;

    # outside required timeframe
    return 0 if $time < 197001010000 || $time > 203801191414;

    return 1;

} # End of ValidISO

# Convert a an ISO time value into UNIX format
sub ISO2UNIX {
	my $isotime = shift;

	if ( !ValidISO($isotime) ) {
		return 0;
	}

	$isotime =~ s/\-//g;	# allow '-' to structur time string

	# 2004 02 13 12 45 /
	my $sec = 0;
	my ( $year, $mon, $mday, $hour, $min ) = $isotime =~ /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})/;
	$mon--;

	# round down to nearest 5 min slot
	my $diff = $min % 5;
	if ( $diff ) {
		$min -= $diff;
	}

	my $unixtime = Time::Local::timelocal($sec,$min,$hour,$mday,$mon,$year);

	return $unixtime;

} # End of ISO2UNIX

sub CreateSubdirHierarchy {
	my $t	   	= shift;	# UNIX time format
	my $channel = shift;

	my $layout	= $NfConf::SUBDIRLAYOUT;
	if ( !defined $layout || $layout == 0 ) {
		return '';
	}

	my @subdir_def = (
		"",
		"%Y/%m/%d",
		"%Y/%m/%d/%H",
		"%Y/%W/%u",
		"%Y/%W/%u/%H",
		"%Y/%j",
		"%Y/%j/%H",
		"%F",
		"%F/%H"
	);

	if ( $layout > $#subdir_def ) {
		return undef;
	}

	my $subdirs =  strftime $subdir_def[$layout], localtime($t);

	# make sure all required sub directories exist
	if ( defined $subdirs && length $subdirs > 0 ) {
		if ( ! -d "$channel/$subdirs" ) {
			my $path = "$channel";
			foreach my $dir ( split /\//, $subdirs ) {
				$path = "$path/$dir";
				if ( !-d $path ) {
					mkdir $path || die "mkdir $path failed: $!. Could not create new sub dir layout";
					chmod 0775, $path || die "Can't chmod '$path': $!\n";
					chown $uid, $gid, $path || die "Can't chown '$path': $!\n";
				}
			}
		}
	} else {
		die "strftime failed! Could not create new sub dir layout";
	}

	return $subdirs;


} # End of SubdirHierarchy

sub wanted {
	my $file = $File::Find::name;
	my $dir = $File::Find::dir;

	# return unless -f $_;
	# return unless /^nfcapd\.\d+$/;

	if ( -f $_ ) {
		#print "FILE: $File::Find::name, NAME: $_\n";
		my ($t_iso) = $_ =~ /nfcapd\.(\d+)/;
		return unless defined $t_iso;
		my $t_unix  = ISO2UNIX($t_iso);
		my $subdirs = CreateSubdirHierarchy($t_unix, $profiledir);
		if ( $File::Find::name ne "$profiledir/$subdirs/$_" ) {
			print "$_ => $subdirs/$_                 \r";
			rename $File::Find::name, "$profiledir/$subdirs/$_" ||
				die "rename failed: $!. Could not create new sub dir layout";
		} else {
			print "$File::Find::name old/new file name identical\r";
		}
	}
	if ( -d $_ ) {
		#print "DIR : $File::Find::dir, NAME: $_\n";
		rmdir "$File::Find::dir/$_";
	}

} #

########################
#
# Main starts here
#
########################

$| = 1; # unbuffered stdout

if ( !NfConf::LoadConfig() ) {
	die "$Log::ERROR\n";
}

# need to run as root
if ( !NfSen::root_process() ) {
	die "nfsen setup wants to run as root\n";
}


if ( !defined $NfConf::SUBDIRLAYOUT ) {
	die "No sub hierachy layout defined in config file\n";
}
my $hints = NfSen::LoadHints();

my $t = time();
my $subdirs = NfSen::SubdirHierarchy($t - ($t % 300));
if ( !defined $subdirs ) {
	die "Unknown sub hierarchy layout $NfConf::SUBDIRLAYOUT\n";
}

# get confirmation
print "Current old layout is '$$$hints{'subdirlayout'}'\n";
print "Configured new layout is '$NfConf::SUBDIRLAYOUT'\n";
print "Apply new layout to all NfSen profiles:\n";
my @AllProfileGroups = NfProfile::ProfileGroups();
foreach my $profilegroup ( @AllProfileGroups ) {
	my @AllProfiles = NfProfile::ProfileList($profilegroup);
	foreach my $profile ( @AllProfiles ) {
		print "	=> $profilegroup/$profile\n";
	}
}
print "This will reorganize all your data files. You may again rebuild your hierarchy any time later\n";
my $ans;
do {
	print "Do you want to continue yes/[no] ";
	$ans = <stdin>;
	chomp $ans;
	# Default answer is no
	if ( $ans eq '' ) {
		$ans = 'no';
	}
} while ( $ans !~ /^yes$/i && $ans !~ /^no$/i );

# Exit on answer 'no'
if ( $ans =~ /^no$/i ) {
	print "OK - exit $0 - nothing changed.\n";
	exit(0);
}

$uid = getpwnam($NfConf::USER);
$gid = getgrnam($NfConf::WWWGROUP);

if ( !defined $uid || !defined $gid ) {
	die "Can't get uid/gid from system for $NfConf::USER/$NfConf::WWWGROUP";
} 

# go ahead
print "Make sure NfSen is not runnig: shut down NfSen:\n";
NfSenRC::NfSen_stop();

foreach my $profilegroup ( @AllProfileGroups ) {
	my @AllProfiles = NfProfile::ProfileList($profilegroup);
	foreach my $profile ( @AllProfiles ) {
		print "Process profile '$profilegroup/$profile'\n";
		my %profileinfo = NfProfile::ReadProfile($profile, $profilegroup);
		my $profilepath = NfProfile::ProfilePath($profile, $profilegroup);
		if ( $profileinfo{'status'} eq 'empty' ) {
			# it's an error reading this profile
			print STDERR "Error reading profile '$profilegroup/$profile'";
			if ( defined $Log::ERROR ) {
				print STDERR ": $Log::ERROR";
			}
			print STDERR "\n";
			die "Abort $0 - Rebuild incomplete. Fix errors and rerun $0\n";
		}
		my @ProfileSources = keys %{$profileinfo{'channel'}};
		foreach $source ( @ProfileSources ) {
			print "$source:\n";
			$profiledir = "$NfConf::PROFILEDATADIR/$profilepath/$source";
			find({ wanted => \&wanted, bydepth => 1 }, $profiledir);
			print "\n";
		}
		print "\n";
	}
}

print "All profiles converted.\n";

$$$hints{'subdirlayout'} = $NfConf::SUBDIRLAYOUT;
NfSen::StoreHints();

do {
	print "Do you want to start NfSen right now? yes/[no] ";
	$ans = <stdin>;
	chomp $ans;
	# Default answer is no
	if ( $ans eq '' ) {
		$ans = 'no';
	}
} while ( $ans !~ /^yes$/i && $ans !~ /^no$/i );

# Exit on answer 'no'
if ( $ans =~ /^no$/i ) {
	print "OK - You need to run '$NfConf::BINDIR/nfsen.rc start' manually\n";
	exit(0);
}

NfSenRC::NfSen_start();
