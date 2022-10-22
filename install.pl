#!/usr/bin/perl
#
#
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#	 this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#	 this list of conditions and the following disclaimer in the documentation
#	 and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#	 used to endorse or promote products derived from this software without
#	 specific prior written permission.
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
#  $Id: install.pl 71 2017-01-19 16:16:21Z peter $
#
#  $LastChangedRevision: 71 $
#
#  Last changed date:    $Date: 2017-01-19 17:16:21 +0100 (Thu, 19 Jan 2017) $

require v5.10.1;

use lib "./installer-items";
use lib "./libexec";
use strict;

# from libexec - the new modules
use NfSen;
use NfProfile;
use NfSenRRD;
use Nfsync;
use Nfsources;

# from installer-items - helper modules
use CopyRecursive;
use File::Copy;
use File::Path;
use RRDconvertv1;

my $VERSION = '$Id: install.pl 71 2017-01-19 16:16:21Z peter $';
my $nfsen_version = "1.3.8";

my @ProfileTag = ( 
	"# \n",
	"# Profile live.\n",
	"# \n",
);

my @RequiredDirs = ( 'PREFIX', 'BINDIR', 'LIBEXECDIR', 'CONFDIR', 'DOCDIR', 
					 'VARDIR', 'PIDDIR', 'FILTERDIR', 'PROFILESTATDIR', 'PROFILEDATADIR', 
					 'BACKEND_PLUGINDIR', 'FRONTEND_PLUGINDIR', 'HTMLDIR' );
#

sub FindCommand {
	my $command = shift;

	my $fullpath = undef;
	my @path = split /:/, $ENV{'PATH'};
	foreach my $dir ( @path ) {
		if ( -x "$dir/$command" ) {
			$fullpath = "$dir/$command";
			last;
		}
	}
	return $fullpath;
	
} # End of FindCommand

# 
# Get Perl
sub GetPerl {

	my $whichperl;
	my $ans;
	$whichperl = FindCommand("perl");
	if ( defined $whichperl ) {
		print "Perl to use: [$whichperl] ";
		chomp($ans = <STDIN>);
		if ( length $ans ) {
			$whichperl = $ans;
		}
	} else {
		print "No Perl found in your PATH. Please specify where to find perl [] ";
		chomp($whichperl = <STDIN>);
	}

	while (1) {
		if ( -x $whichperl ) {
			my $err = system("$whichperl -e 'require 5.10.1;'") >> 8;
			last if $err == 0;
			print "Found errors while testing Perl\n";
		} else {
			print "No executable: '$whichperl'\n";
		}
		print "Perl to use: [] ";
		chomp($whichperl = <STDIN>);
	}

	return $whichperl;

} # End of GetPerl

sub CopyDir {
	my $orig = shift;
	my $dest = shift;

	my $DIR;
	mkpath($dest, 1, 0755) unless -d $dest;
	opendir($DIR, $orig) || die "can't open dir $orig: $!\n";
	while ( my $direntry = readdir $DIR ) {
		next if $direntry eq '.';
		next if $direntry eq '..';
		next if $direntry eq '.svn';
		if ( -d "$orig/$direntry" ) {
			CopyDir("$orig/$direntry", "$dest/$direntry");
			next;
		} 
		if ( -f "$dest/$direntry" || -l "$dest/$direntry") {
			unlink "$dest/$direntry";
		}
		CopyRecursive::fcopy("$orig/$direntry", "$dest/$direntry");
	}

	closedir $DIR;

} # End of CopyDir

#
# user $user needs to exist and must be a member of $WWWGROUP
sub VerifyUser {
	my $user = shift;

	my $www_gid = getgrnam($NfConf::WWWGROUP);

	my ($login,$pass,$uid,$user_gid) = getpwnam($user);
	if ( !defined $login ) {
		die "user '$user' not found on this system\n";
	}

	# Verify if $user has gid of $WWWGROUP
	if ( $user_gid == $www_gid ) {
		return $uid;
	}

	# Not yet found - check if $user is a member of $WWWGROUP
	my ($gid_name,$passwd,$group_gid,$group_members) = getgrgid($www_gid);
	if ( !defined $gid_name ) {
		die "Group '$user_gid' not found on this system\n";
	}
	# Check the members list
	foreach my $member ( split /\s+/, $group_members ) {
		if ( $member eq $user ) {
			# user found
			return $uid;
		}
	}
	die "User '$user' not a member of group '$NfConf::WWWGROUP'\n";

} # End of VerifyUser

sub VerifyConfig {

	# check if the vars of all required dirs are defined in the Config file
	my $missing = 0;
	foreach my $dir ( @RequiredDirs ) {
		my $var = "NfConf::${dir}";
		no strict 'refs';
		if ( !defined ${$var} ) {
			print STDERR "Missing Variable \$$dir in Config File\n";
			$missing++;
		}
		use strict 'refs';
	}
	if ( $missing ) {
		print STDERR "\nSome variables are missing in your config file.\n";
		print STDERR "If you upgrade from an older version of NfSen please check nfsen-dist.conf\n";
		print STDERR "for required variables.\n\n";
		exit;
	}

	die "Missing PREFIX directory of nfdump tools!\n" unless defined $NfConf::PREFIX;
	die "Configured PREFIX directory '$NfConf::PREFIX' not found!\n" unless -d  $NfConf::PREFIX;
	foreach my $binary ( 'nfcapd', 'nfdump', 'nfprofile' ) {
		die "nfdump tools installation error: '$binary' not found in '$NfConf::PREFIX'" unless -f "$NfConf::PREFIX/$binary";
	}

	my @out = `$NfConf::PREFIX/nfdump -V`;
	if ( scalar @out <= 0 ) {
		die "Error getting nfdump version";
	}
	chomp $out[0];
	my ($major, $minor) = $out[0] =~ /Version:\s(\d)\.(\d+)/;
	if ( defined $major && defined $minor) {
		if ( $major >= 1 && $minor >= 6 ) {
			print "Found $out[0]\n";
		} elsif ( $out[0] =~ /Version:\s1.5.8-\d+-NSEL/ )  {
			print "Found nfdump NSEL\n";
		} else {
			print "$out[0]\n";
			die "Nfdump version not compatible with current NfSen version.\n";
		}
	} 

	my $www_gid = getgrnam($NfConf::WWWGROUP) || 
		die "WWW group '$NfConf::WWWGROUP' not found on this system\n";

	my $nfsen_uid = VerifyUser($NfConf::USER);

	die "NFSEN does not want to run as root!\n" if $NfConf::USER eq 'root';

	my $subdir = NfSen::SubdirHierarchy(time());
	if ( !defined $subdir ) {
		die "Selected subdir hierarchy %NfConf::SUBDIRLAYOUT out of range\n";
	}

	if ( !Nfsources::ValidateSources() ) {
		die "Fix errors for %source in your config file and retry!\n";
	}

	if ( !defined $NfConf::low_water ) {
		die "Low water mark not set - Expiration does not work";
	}

	if ( $NfConf::low_water > 0 && $NfConf::low_water < 1 ) {
		my $new_mark = 100*$NfConf::low_water;
		die "Replace \$low_water = $NfConf::low_water by \$low_water = $new_mark in nfsen.conf";
	}

	if ( $NfConf::low_water < 0 || $NfConf::low_water > 100 ) {
		die "\$low_water = $NfConf::low_water outside range 1..100";
	}

	return ($nfsen_uid, $www_gid );

} # End of VerifyConfig

#
# Patching: 
# Any string %%varname%% is replaced by the true value $NfCon::varname from 
# the config file
sub PatchVars {
	my $file = shift;

	open FILE, "$file" || die "Can't open file '$file' for reading: $!\n";
	my @lines = <FILE>;
	close FILE;

	open FILE, ">$file" || die "Can't open file '$file' for writing: $!\n";
	foreach my $line ( @lines ) {
		if ( $line =~ /%%(.+)%%/ ) {
			my $var = "NfConf::$1";
			no strict 'refs';
			$line =~ s#%%(.+)%%#${$var}#;
			use strict 'refs';
		}
		print FILE $line;
	}
	close FILE;

} # End of PatchVars

sub PatchAllScripts {

	my %GlobList = ( 
		"bin/*"		=> 	"$NfConf::INSTPREFIX$NfConf::BINDIR",
		"libexec/*"	=>	"$NfConf::INSTPREFIX$NfConf::LIBEXECDIR"
	);

	foreach my $glob_list ( keys %GlobList ) {
		my $dir 	= $GlobList{$glob_list};
		my @Scripts	= glob($glob_list);
		print "In directory: $dir ...\n";
		foreach my $script (@Scripts) {
			$script =~ s#^.+/##;
			if ( -f "$dir/$script" ) {
				print "Update script: $script\n";
				PatchVars("$dir/$script");
			} else {
				print "ERROR: Failed to update script: '$script'. Installation incomplete!\n";
			}
		}
	}

	print "\n";

} # End of PatchAllScripts

sub RenameFiles {

	print "Rename gif RRDfiles ... ";
	my @AllProfileGroups = NfProfile::ProfileGroups();
	foreach my $profilegroup ( @AllProfileGroups ) {
		my @AllProfiles = NfProfile::ProfileList($profilegroup);
		if ( scalar @AllProfiles > 0 ) {
			foreach my $profile ( @AllProfiles ) {
				foreach my $type (  'flows', 'packets', 'traffic' ) {
					foreach my $periode (  'day', 'week', 'month',  'year' ) {
						my $oldfile = "$NfConf::INSTPREFIX$NfConf::PROFILESTATDIR/$profilegroup/$profile/${type}-${periode}.gif";
						my $newfile = "$NfConf::INSTPREFIX$NfConf::PROFILESTATDIR/$profilegroup/$profile/${type}-${periode}.png";
						if ( -f $oldfile ) {
							rename $oldfile, $newfile;
						}
					}
				}
			}
		}
	}
	print "done.\n";

} # End of RenameFiles

sub SetupHTML {
	my ( $nfsen_uid, $www_gid ) = @_;

	print "Setup php and html files.\n";
	mkpath("$NfConf::INSTPREFIX$NfConf::HTMLDIR", 1, 0755) unless -d "$NfConf::INSTPREFIX$NfConf::HTMLDIR";
	die "Could not create HTMl directory '$NfConf::INSTPREFIX$NfConf::HTMLDIR': $!\n"  unless -d "$NfConf::INSTPREFIX$NfConf::HTMLDIR";

	$CopyRecursive::CopyLink = 1;
	$CopyRecursive::MODE 	 = 0644;
	$CopyRecursive::UID 	 = 0;
	$CopyRecursive::GID 	 = $www_gid;
	CopyRecursive::dircopy("html", "$NfConf::INSTPREFIX$NfConf::HTMLDIR");
	open CONF, ">$NfConf::INSTPREFIX$NfConf::HTMLDIR/conf.php" || die "Can't open conf.php for writing: $!\n";
	print CONF "<?php\n";
	print CONF "/* This file was automatically created by the NfSen $nfsen_version install.pl script */\n\n";
	print CONF "\$COMMSOCKET = \"$NfConf::COMMSOCKET\";\n";
	print CONF "\n\$DEBUG=0;\n";
	print CONF "\n?>\n";
	close CONF;
	print "\n";
	
} # End of SetupHTML

sub SetupEnv {
	my $nfsen_uid	= shift;
	my $www_gid		= shift;
	
	# Make sure all required directories exist

	umask 0002;
	print "\nSetup diretories:\n";
	my @dirs = (
		"$NfConf::INSTPREFIX$NfConf::VARDIR",
		"$NfConf::INSTPREFIX$NfConf::VARDIR/tmp",
		"$NfConf::INSTPREFIX$NfConf::PIDDIR",
		"$NfConf::INSTPREFIX$NfConf::FILTERDIR",
		"$NfConf::INSTPREFIX$NfConf::FORMATDIR",
		"$NfConf::INSTPREFIX$NfConf::PROFILESTATDIR",
		"$NfConf::INSTPREFIX$NfConf::PROFILESTATDIR/live",
		"$NfConf::INSTPREFIX$NfConf::PROFILEDATADIR",
		"$NfConf::INSTPREFIX$NfConf::PROFILEDATADIR/live",
	);

	print "\nUse UID/GID $nfsen_uid $www_gid\n";

	foreach my $dir ( @dirs ) {
		if ( ! -d $dir ) {
			print "Creating: ";
			mkpath($dir, 1, 0755) || die "Can't mkpath '$dir': $!\n";
		} else {
			print "Exists: ";
		}
		chmod 0775, $dir || die "Can't chmod '$dir': $!\n";
		chown $nfsen_uid, $www_gid, $dir || die "Can't chown '$dir': $!\n";
		print "$dir\n";
	}

	print "\nProfile live: spool directories:\n";
	foreach my $ident ( keys %NfConf::sources ) {
		my $dir = "$NfConf::PROFILEDATADIR/live/$ident";
		if ( ! -d $dir ) {
			print "Creating: ";
			mkpath($dir, 1, 0755) || die "Can't mkpath '$dir': $!\n";
		} else {
			print "Exists: ";
		}
		chmod 0775, $dir || die "Can't chown '$dir': $!\n";
		chown $nfsen_uid, $www_gid, $dir || die "Can't chown '$dir': $!\n";
		print "$ident\n";
	}

	RenameFiles();

	my $now = time();
	my $tstart = $now - ( $now % $NfConf::CYCLETIME );
	foreach my $db ( keys %NfConf::sources ) {
		NfSenRRD::SetupRRD("$NfConf::PROFILESTATDIR/live", $db, $tstart - $NfConf::CYCLETIME, 0);
	}
	if ( $Log::ERROR ) {
		die "Error setup RRD DBs: $Log::ERROR\n";
	}

	my %profileinfo = NfProfile::ReadProfile('live', '.');
	if ( $profileinfo{'status'} eq 'empty' ) {
		print "Create profile info for profile 'live'\n";
		# empty - new profile
		$profileinfo{'_comment_'} 	= \@ProfileTag;
		$profileinfo{'name'}		= 'live';
		$profileinfo{'tcreate'} 	= $tstart;
		$profileinfo{'tbegin'}		= $tstart;
		$profileinfo{'tstart'} 		= $tstart;
		$profileinfo{'tend'} 		= $tstart;
		$profileinfo{'updated'}		= $tstart - $NfConf::CYCLETIME;
		$profileinfo{'expire'} 		= 0;
		$profileinfo{'maxsize'} 	= 0;
		$profileinfo{'size'} 		= 0;
		$profileinfo{'type'} 		= 0;
		$profileinfo{'locked'} 		= 0;
		$profileinfo{'status'} 		= 'OK';
		$profileinfo{'version'} 	= $NfProfile::PROFILE_VERSION;
		$profileinfo{'channel'}		= {};
		my $order = 1;
		foreach my $source ( keys %NfConf::sources ) {
			$profileinfo{'channel'}{$source}{'sign'}   = '+';
			$profileinfo{'channel'}{$source}{'colour'} = $NfConf::sources{$source}{'col'};
			$profileinfo{'channel'}{$source}{'order'}  = $order++;
			$profileinfo{'channel'}{$source}{'sourcelist'}  = $source;
		}
		NfProfile::WriteProfile(\%profileinfo);
	} else {
		print "Use existing profile info for profile 'live'\n";
	}

	my $filelist = "$NfConf::PROFILESTATDIR/live/*rrd $NfConf::PROFILESTATDIR/live/profile.dat";
	my @AllFIles = glob($filelist);
	chown $nfsen_uid, $www_gid, @AllFIles;

	print "\n";

} # End of SetupEnv

sub FixBrokenLive {
	my $liveprofile = shift;

	foreach my $channel ( NfProfile::ProfileChannels($liveprofile) ) {
		if ( !defined $$liveprofile{'channel'}{$channel}{'sourcelist'} ||
			  $$liveprofile{'channel'}{$channel}{'sourcelist'} ne $channel ) {
			$$liveprofile{'channel'}{$channel}{'sourcelist'} = $channel;
			print "Fix broken channel info for '$channel'\n";
		}
	}

} # End FixBrokenLive

sub UpgradeProfiles {
	my $nfsen_uid	= shift;
	my $www_gid		= shift;

	my @AllProfiles = NfProfile::ProfileList('.');
	if ( scalar @AllProfiles == 0 ) {
		print STDERR "$Log::ERROR\n" if defined $Log::ERROR;
		return;
	}

	Nfsync::seminit();
	$CopyRecursive::UID 	 = $nfsen_uid;
	$CopyRecursive::GID 	 = $www_gid;
	$CopyRecursive::MODE 	 = 0644;

	# fix permissions - all files/directories should ne $NfConf::USER and no longer WWW, as 
	# no php script will no longer write anything
	chown $nfsen_uid, $www_gid, "$NfConf::PROFILEDATADIR";
	chown $nfsen_uid, $www_gid, "$NfConf::PROFILESTATDIR";

	foreach my $profilename ( @AllProfiles ) {
		my %profileinfo = NfProfile::ReadProfile($profilename, '.');

		# Upgrade snapshots
		if ( $profileinfo{'version'} == $NfProfile::PROFILE_VERSION && $profileinfo{'tcreate'} == 0 ) {
			print "Upgrade profile '$profilename' from snapshot\n";
			# estimate create time of profile
			my $tcreate = (stat("$NfConf::PROFILESTATDIR/$profilename"))[9];
			$profileinfo{'tcreate'}	= $tcreate;
			$profileinfo{'tbegin'}	= $tcreate - ( $tcreate % $NfConf::CYCLETIME );

			NfProfile::WriteProfile(\%profileinfo);
		}

		# 1.3 introduces a version parameter for the profile
		next if $profileinfo{'version'} >= $NfProfile::PROFILE_VERSION;

		print "Upgrade profile '$profilename' to version '$NfProfile::PROFILE_VERSION'\n";
		$profileinfo{'version'} = $NfProfile::PROFILE_VERSION;
		$profileinfo{'group'} 	= '.';
	
		# fix permissions - all files/directories should ne $NfConf::USER and no longer WWW, as 
		# no php script will no longer write anything
		chown $nfsen_uid, $www_gid, "$NfConf::PROFILEDATADIR/$profilename";
		chown $nfsen_uid, $www_gid, "$NfConf::PROFILESTATDIR/$profilename";

		# 1.3 introduces channels and no longer has a sourcelist
		if ( exists $profileinfo{'legacy'} && exists $profileinfo{'legacy'}{'sourcelist'} ) {
			my $order = 1;
			my $oldfilter = undef;
			foreach my $channel ( split /:/, $profileinfo{'legacy'}{'sourcelist'} ) {
				$profileinfo{'channel'}{$channel}{'sign'}   = '+';
				$profileinfo{'channel'}{$channel}{'colour'} = $NfConf::sources{$channel}{'col'};
				$profileinfo{'channel'}{$channel}{'order'}  = $order;
				$profileinfo{'channel'}{$channel}{'sourcelist'}  = $channel;
				$order++;

				next if $profilename eq 'live';
				# copy filter files

				if ( $profileinfo{'type'} == 1 ) {
					$oldfilter	= "$NfConf::PROFILEDATADIR/$profilename/history_filter.txt";
				} else {
					$oldfilter	= "$NfConf::PROFILEDATADIR/$profilename/filter.txt";
				}
				my $newfilter = "$NfConf::PROFILESTATDIR/$profilename/$channel-filter.txt";

				CopyRecursive::fcopy($oldfilter,$newfilter) or 
					$oldfilter = undef,
					print STDERR "Could not copy filter file: $!\n";
			}
			NfProfile::WriteProfile(\%profileinfo);
			unlink $oldfilter if defined $oldfilter;
		}
	}

	my %profileinfo = NfProfile::ReadProfile('live', '.');
	FixBrokenLive(\%profileinfo);
	NfProfile::WriteProfile(\%profileinfo);

	foreach my $profilegroup ( NfProfile::ProfileGroups() ) {
		my @AllProfiles = NfProfile::ProfileList($profilegroup);
		foreach my $profilename ( NfProfile::ProfileList($profilegroup) ) {
			my %profileinfo = NfProfile::ReadProfile($profilename, $profilegroup);
			my $profilepath = NfProfile::ProfilePath($profilename, $profilegroup);

			next if ($profileinfo{'type'} & 4) > 0;

			foreach my $channel ( keys %{$profileinfo{'channel'}} ) {
				if( ! -f "$NfConf::PROFILEDATADIR/$profilepath/$channel/.nfstat") { 
					# no shadow profile, but missing channel stat
					print "Rebuilding profile stats for '$profilegroup/$profilename'\n";
					NfProfile::DoRebuild(\%profileinfo, $profilename, $profilegroup, $profilepath, 1, 0);
					NfProfile::WriteProfile(\%profileinfo);
				}
				# make sure it's own by nfsen_uid after the rebuild
				chown $nfsen_uid, $www_gid, "$NfConf::PROFILEDATADIR/$profilepath/$channel/.nfstat";
			}

			# make sure, everything is owened by right uid/gid
			my @AllEntries = <$NfConf::PROFILESTATDIR/$profilename/*>;
			chown $nfsen_uid, $www_gid, @AllEntries;
			my @AllEntries = <$NfConf::PROFILEDATADIR/$profilename/*>;
			chown $nfsen_uid, $www_gid, @AllEntries;

		}
	}
	Nfsync::semclean();


} # End of UpgradeProfiles

sub CopyAllFiles {
	my $ConfigFile	= shift;
	my $nfsen_uid	= shift;
	my $www_gid		= shift;

	print "Copy NfSen dirs etc bin libexec plugins doc ...\n";

	$CopyRecursive::CopyLink = 1;
	$CopyRecursive::UID 	 = 0;
	$CopyRecursive::GID 	 = $www_gid;
	$CopyRecursive::MODE 	 = 0755;
	unlink "$NfConf::BINDIR/nfsen.rc";
	CopyRecursive::dircopy("bin", "$NfConf::INSTPREFIX$NfConf::BINDIR");
	CopyRecursive::dircopy("libexec", "$NfConf::INSTPREFIX$NfConf::LIBEXECDIR");
	$CopyRecursive::MODE 	 = 0644;
	CopyRecursive::dircopy("etc", "$NfConf::INSTPREFIX$NfConf::CONFDIR");
	CopyRecursive::dircopy("plugins/backend",  "$NfConf::INSTPREFIX$NfConf::BACKEND_PLUGINDIR");
	CopyRecursive::dircopy("plugins/frontend", "$NfConf::INSTPREFIX$NfConf::FRONTEND_PLUGINDIR");

	if ( $ConfigFile eq "$NfConf::CONFDIR/nfsen.conf" ) {
		print "Keep config file '$ConfigFile'\n";
	} else {
		print "Copy config file '$ConfigFile'\n";
		CopyRecursive::fcopy("$ConfigFile", "$NfConf::CONFDIR/nfsen.conf");
	}
	print "\n";

} # End of CopyAllFiles

sub Cleanup {
	
	print "Cleanup old files ...\n";

	my @OldFiles = ( "$NfConf::BINDIR/GenGraph.pl" ,
					 "$NfConf::BINDIR/pid_check.pl",
					 "$NfConf::BINDIR/nfsen-run",
					 "$NfConf::LIBEXECDIR/demoplugin.pm",
					 "$NfConf::LIBEXECDIR/PluginTemplate.pm",
					 "$NfConf::CONFDIR/nfsen-shell-param",
					);

	foreach my $file ( @OldFiles ) {
		unlink $file if -f $file;
	}

} # End of Cleanup

########################
#
# Main starts here
#
########################

$| = 1;

my $ConfigFile = shift @ARGV;


# Load the required NfSen modules 
unshift @INC, "libexec";
print "Check for required Perl modules: ";
eval {
	# other required modules
	use v5.10.1;
	use RRDs;
	use Mail::Header;
	use Mail::Internet;
	use Socket6 qw(inet_pton);
};
if ( $@ ) {
	print "Failed\nRequired nfsen modules not found\n";
	print "$@\n";
	exit;
} else {
	print "All modules found.\n";
}

# need to run as root
if ( !NfSen::root_process() ) {
	die "nfsen setup wants to run as root\n";
}

# need a config file
if ( !defined $ConfigFile ) {
	die "Config file required: $0 <nfsen.conf>\n";
}
if ( ! -f $ConfigFile ) {
	die "$ConfigFile: No such file.\n";
}

# Load the config
if ( !NfConf::LoadConfig($ConfigFile) ) {
	print "$Log::ERROR\n";
	exit 1;
}

# check for extra errornous nfsen.conf file, which may overwrite existing files
if ( -f "$NfConf::CONFDIR/nfsen.conf" && -f "etc/nfsen.conf" &&
	( (stat($ConfigFile))[1] != (stat("etc/nfsen.conf"))[1] )) {
	die "Extra nfsen.conf file in etc directory found. Remove errornous file first"
}

Log::LogInit();

my $hints = NfSen::LoadHints();
if ( $$$hints{'version'} == -1 ) {
	# initial NfSen install or upgrade from old version without hints
	$$$hints{'version'} 		= $nfsen_version;
	$$$hints{'subdirlayout'} 	= $NfConf::SUBDIRLAYOUT;
} else {
	print "Upgrade from version '$$$hints{'version'}' installed at " . scalar localtime $$$hints{'installed'};
	print "\n";
}


my $rrd_version = $RRDs::VERSION;
die "Can't find out which version of RRD you are using!\n" unless defined $rrd_version;

$NfConf::RRDoffset = NfSenRRD::GetRRDoffset();
if ( !defined $NfConf::RRDoffset ) {
	die "$Log::ERROR\n";
}

# 
print "Setup NfSen:\n";
print "Version: $nfsen_version: $VERSION\n\n";

# Get Perl
# Put this into a NfConf variable, so we can use the standard Patch Procedure
$NfConf::PERL = GetPerl();
$NfConf::INSTPREFIX = $ENV{'INSTPREFIX'};
if ( defined $NfConf::INSTPREFIX ) {
	if ( ! $NfConf::INSTPREFIX =~ /\/$/ ) {
		$NfConf::INSTPREFIX = $NfConf::INSTPREFIX . '/';	# make sure path ends with a '/' 
	}
	print "Install prefixdir: '$NfConf::INSTPREFIX'\n";
} else {
	$NfConf::INSTPREFIX = '';
}


my ($nfsen_uid, $www_gid ) = VerifyConfig();
my $nfsen_run = 0;

# test for two files of old layout
my $need_rrdlayout_upgrade = -f "$NfConf::PROFILESTATDIR/live/flows.rrd" && -f "$NfConf::PROFILESTATDIR/live/packets_other.rrd";

my $rrdtool = undef;
if ( $need_rrdlayout_upgrade ) {
	$rrdtool = FindCommand("rrdtool");
	if ( !defined $rrdtool ) {
		print "\nERROR: command 'rrdtool' not found in your PATH: 'rrdtool' is needed to upgrade the DBs of your NfSen version\n";
		exit 1;
	}
}

my $pid_name = "nfsend.pid";

if ( -f "$NfConf::PIDDIR/$pid_name" ) {
	my ($major, $minor, $release) = split /\./, $$$hints{'version'};
	if ( $release < 5 ) {
		# for older releases than 1.3.5 upgrade we to stop nfsen completely
		print "Stop NfSen completely while upgrading to version $nfsen_version\n";
		$nfsen_run = 2;	# a complete restart needed
		system("$NfConf::BINDIR/nfsen stop");
	} else {
		open PID, "$NfConf::PIDDIR/$pid_name" || die "Can't open pid file: $!\n";
		my $pid = <PID>;
		chomp($pid);
		close PID;
		die "Can't extract PID out of '$NfConf::PIDDIR/$pid_name'. Stop upgrade" if !defined $pid;
		if ( kill(0, $pid) == 1 ) {
			print "Stop nfsend while upgrading .";
			kill 15, $pid;
			my $cnt = 0;
			while ( -f "$NfConf::PIDDIR/$pid_name" && $cnt < $NfConf::CYCLETIME ) {
				print ".";
				$cnt++;
				sleep(1);
			}
			if ( -f "$NfConf::PIDDIR/$pid_name" ) {
				print "\nnfsend doesn't want to die! It's not save to upgrade NfSen!\n";
				exit;
			} else {
				print "done.\n";
				$nfsen_run = 1;
			}
		} else {
			print "nfsend pid file exists, but no process is running.\n";
			unlink "$NfConf::PIDDIR/$pid_name";
		}
	}
}

SetupHTML($nfsen_uid, $www_gid);
CopyAllFiles($ConfigFile, $nfsen_uid, $www_gid);
PatchAllScripts();
Cleanup();
SetupEnv($nfsen_uid, $www_gid);

UpgradeProfiles($nfsen_uid, $www_gid);

if ( $need_rrdlayout_upgrade ) {
	print "The profiles need be be updated to new RRD layout:\n";
	print "Use '$rrdtool' to dump current DBs\n";

	my @AllProfiles = NfProfile::ProfileList('.');
	if ( scalar @AllProfiles == 0 ) {
		print STDERR "$Log::ERROR\n" if defined $Log::ERROR;
		return;
	}
	foreach my $profilename ( @AllProfiles ) {
		if ( !RRDconvertv1::UpdateProfile($profilename, $rrdtool) ) {
			print "ERROR updating profile! NfSen installation incomplete\n";
			exit 0;
		}
	}
}

if ( !exists $$$hints{'sources'} ) {
	foreach my $source ( sort keys %NfConf::sources ) {
		my $port = $NfConf::sources{$source}{'port'};
		$$$hints{'sources'}{$source} = $port;
	}
}

Nfsources::Reconfig();
delete $$$hints{'sources'};
foreach my $source ( sort keys %NfConf::sources ) {
	$$$hints{'sources'}{$source} = $NfConf::sources{$source}{'port'};
}


$$$hints{'version'} 		= $nfsen_version;
$$$hints{'installed'} 		= time();
NfSen::StoreHints();
chown $nfsen_uid, $www_gid, "$NfConf::INSTPREFIX$NfConf::PROFILESTATDIR/hints" || die "Can't chown hints db: $!\n";
print "Setup done.\n\n";

if ( $nfsen_run == 2 ) {
	print "Restart NfSen\n";
	system("$NfConf::BINDIR/nfsen start");
} elsif ( $nfsen_run == 1 ) {
	print "Restart nfsend\n";
	system("$NfConf::BINDIR/nfsend");
} 

print "* You may want to subscribe to the nfsen-discuss mailing list:\n";
print "* http://lists.sourceforge.net/lists/listinfo/nfsen-discuss\n";
print "* Please send bug reports back to me: phaag\@sourceforge.net\n";
exit 0;

