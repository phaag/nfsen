#!%%PERL%%
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#	  this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#	  this list of conditions and the following disclaimer in the documentation
#	  and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#	  used to endorse or promote products derived from this software without
#	  specific prior written permission.
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
#  $Id: NfAlert.pm 69 2014-06-23 19:27:50Z peter $
#
#  $LastChangedRevision: 69 $

package NfAlert;

use strict;
use Sys::Syslog; 
use IO::Socket::INET;
use Fcntl qw(:DEFAULT :flock);
use Storable qw(lock_store lock_retrieve);
use POSIX ":sys_wait_h";
use POSIX 'strftime';
use Mail::Header;
use Mail::Internet;

use NfSen;
use NfSenRRD;
use Nfcomm;
use Nfsync;
use Log;

our %AlertPluginsCondition;
our %AlertPluginsAction;

our $ALERT_VERSION = 130;	# version 1.3.0

my @AlertKeys = (
	'description',	 # Array of comment lines starting with '#'
	'name', 		 # name of alert
	'status',		 # status of alert
					 # 0 alert disabled
					 # 1 alert enabled
	'version',		 # version of alert.dat
	'type', 		 # type of condition used in this alert
					 # 0: SumStat, 1: FlowStat, 2: plugin
	'trigger_type',  # type of trigger
					 # 0: Each time, 1: Once only, 2: Once only, while true
	'trigger_number', # number of conditions == true required for trigger
	'trigger_blocks', # number of slot the trigger is blocked after it fired
	'channellist',	 # '|' separated list of source channels
	'condition',	 # ':' separated list of condition properties
					 # For SumStat condition:
					 # op:type:comp:comp_type:0:comp_value:scale
					 # 
					 # For FlowStat condition:
					 # op:type:comp:comp_type:stat_type:comp_value:scale
					 #
	'action_type',	 # action to be executed
					 # 0000: no action
				     # 0001: send email
					 # 0010: execute system cmd
					 # 0100: run plugin 
	'action_email',	 # action to be executed
	'action_subject', # action to be executed
	'action_system', # action to be executed
	'action_plugin', # action to be executed
);

# Default alert description
my @AlertTag = ( 
	"# \n",
);

my $LastNum 	 = 12;
my $LastEventNum = 10;

my %AlertRunInfo = (
	'version'	=> $ALERT_VERSION,		# version of binary AlertRunInfo
	'name'		=>	'',					# name of alert
	'created'	=>	0,					# timestamp created
	'enabled'	=>	0,					# timestamp enabled
	'trigger_status'=> 0,				# current trigger status
										# 0000: 0 disabled
										# 0001: 1 trigger armed
					 					# 0011: 3 trigger armed - num conditions not yet reached
					 					# 0101: 5 trigger fired
					 					# 1101: D trigger fired and blocked
	'final_condition' => 0,				# state of last evaluated condition
	'trigger_blocks' => 0,				# number of cycles, trigger blocked
	'cond_cnt'	=>	0,					# number of condition == true in a row
	'updated'	=>  0,					# time last updated
	'duration' 	=> [],					# duration of this slot
	'last'		=> { 'flows' => [], 'packets' => [], bytes => []  },# last value list
	'avg10m'	=> { 'flows' => 0, 'packets' => 0, bytes => 0  },# 10min average 
	'avg30m'	=> { 'flows' => 0, 'packets' => 0, bytes => 0  },# 30min average 
	'avg1h'		=> { 'flows' => 0, 'packets' => 0, bytes => 0  },# 1hour average 
	'avg6h'		=> { 'flows' => 0, 'packets' => 0, bytes => 0  },# 6hour average 
	'avg12h'	=> { 'flows' => 0, 'packets' => 0, bytes => 0  },# 12hour average 
	'avg24h'	=> { 'flows' => 0, 'packets' => 0, bytes => 0  },# 24hour average 
	'trigger_events' => [],				# time of last 10 trigger events
);

my @DSlist = ( 'last', 'avg10m', 'avg30m', 'avg1h', 'avg6h', 'avg12h', 'avg24h' );

my $EODATA 	= ".\n";

sub ReadStatInfo {
	my $alert		= shift;
	my $tslot		= shift;

	my $statinfo 	 = {};
	my $file = "$NfConf::PROFILEDATADIR/~$alert/$alert/nfcapd.$tslot";

	my $err = 'ok';
	if ( ! -f $file ) {
		$err = "No flow file for requested time slot";
		return ($statinfo, $err);
	}

	local $SIG{CHLD} = 'DEFAULT';
	if ( !open(NFDUMP, "$NfConf::PREFIX/nfdump -I -r $file 2>&1 |") ) {
		$err = $!;
		return ( {}, $err);
	} 
	my ( $label, $value );
	while ( my $line = <NFDUMP> ) {
		chomp $line;
		( $label, $value ) = split ':\s', $line;
		next unless defined $label;
		$$statinfo{lc $label} = $value;
	}

	my $nfdump_exit = 0;
	if ( !close NFDUMP ) {
		$nfdump_exit = $?;
		my $exit_value  = $nfdump_exit >> 8;
		my $signal_num  = $nfdump_exit & 127;
		my $dumped_core = $nfdump_exit & 128;
		if ( $exit_value == 250 ) {
			$err = "Failed get stat info for requested time slot";
		} else {
			$err = "Run nfdump failed: Exit: $exit_value, Signal: $signal_num, Coredump: $dumped_core";
		}
	};

	return ($statinfo, $err);

} # End of ReadStatInfo

sub AlertList {

	my @AllAlerts;
	opendir(PROFILEDIR, "$NfConf::PROFILESTATDIR" ) or
		$Log::ERROR = "Can't open profile stat directory: $!", 
		return @AllAlerts;

	@AllAlerts = grep {  -f "$NfConf::PROFILESTATDIR/$_/alert.dat" && $_ !~ /^\./ && s/^~//} 
						readdir(PROFILEDIR);

	closedir PROFILEDIR;

	$Log::ERROR = undef;
	return @AllAlerts;

} # End of AlertList

sub EmptyAlert {

	my %empty;
	# Make sure all fields are set
	foreach my $key ( @AlertKeys ) {
		$empty{$key} = undef;
	}

	$empty{'description'}		= [];
	$empty{'name'}				= undef;
	$empty{'status'}			= 'empty';
	$empty{'version'}			= 0;
	$empty{'type'}				= 0;
	$empty{'trigger_type'}		= 0;
	$empty{'trigger_number'}	= 0;
	$empty{'trigger_blocks'}	= 0;
	$empty{'action_type'}		= 0;
	$empty{'action_email'}		= '';
	$empty{'action_subject'}	= 'Alert';
	$empty{'action_system'}		= '';
	$empty{'action_plugin'}		= '';
	$empty{'condition'}			= [];

	return %empty;

} # End of EmptyAlert

sub AlertExists {
	my $name  		 = shift;

	return -f "$NfConf::PROFILESTATDIR/~$name/alert.dat" ? 1 : 0;

} # End of AlertExists

#
# Returns the alert info hash, if successfull
# else returns EmptyAlert and sets Log::ERROR
sub ReadAlert {
	my $name  		 = shift;

	my %alertinfo = EmptyAlert();
	my $description = [];

	$Log::ERROR	 	= undef;
	my %empty	   	= EmptyAlert();
	$empty{'name'}  = $name;

	if ( ! -f "$NfConf::PROFILESTATDIR/~$name/alert.dat" ) {
		$Log::ERROR = "alert '$name' does not exists";
		return %empty;
	}

	sysopen(AlertFILE, "$NfConf::PROFILESTATDIR/~$name/alert.dat", O_RDONLY) or
		$Log::ERROR = "Can't open alert data file for alert: '$name' : $!",
		return %empty;

	flock AlertFILE, LOCK_SH;

	while ( <AlertFILE> ) {
		chomp;
		next if $_ =~ /^\s*$/;	# Skip empty lines
		if ( $_ =~ /^\s*#\s*(.*)$/ ) {
			push @$description, "$1";
			next;
		}
		my ($key, $value) = split /\s*=\s*/;
		if ( !defined $key ) {
			$Log::ERROR = "Error reading alert information. Unparsable line: '$_'";
			warn $Log::ERROR;
		} 
		if ( !defined $value ) {
			warn "Error reading alert information. Empty value for line: '$_'";
		} 
		if ( exists $empty{"$key"} ) {
			if ( $key eq 'condition' ) {
				push @{$alertinfo{'condition'}}, $value;
			} else {
				$alertinfo{$key} = $value;
			}
		} else {
			$Log::ERROR =  "Error reading alert information. Unknown key: '$key'";
			warn $Log::ERROR;
		}
	}
	$alertinfo{'description'} = $description;
	flock AlertFILE, LOCK_UN;
	close AlertFILE;

	# Make sure all fields are set
	foreach my $key ( @AlertKeys ) {
		next if defined $alertinfo{$key};
		next if $key eq 'version';
		$alertinfo{$key} = $empty{$key};
		warn "Empty key '$key' in alert '$name' - preset default value: $empty{$key}";
	}

	if ( $alertinfo{'name'} ne $name ) {
		$Log::ERROR = "Corrupt dat ifile.";
		return %empty;
	}

	if ( defined $Log::ERROR ) {
		return %empty;
	}

	return %alertinfo;

} # End of ReadAlert

sub ReadAlertFilter {
	my $alert  		 = shift;

	$Log::ERROR = undef;
	# get alert filter
	my $filterfile = "$NfConf::PROFILESTATDIR/~$alert/$alert-filter.txt";
	if ( ! -f $filterfile ) {
		$Log::ERROR = "Missing alert filter file for alert '$alert'";
		return undef;
	}

	my $filter = [];
	if ( !open(FILTER, "$filterfile" ) ) {
		$Log::ERROR = "Can not open alert filter file '$filterfile'";
		return undef;
	}

	@{$filter} = <FILTER>;
	close FILTER;

	return $filter;

} # End of ReadAlertFilter


sub WriteAlert {
	my $alertref = shift;

	my $name  		 = $$alertref{'name'};
	if ( length $name == 0 ) {
		$Log::ERROR = "While writing alert file. Corrupt data ref",
		return undef;
	}

	$Log::ERROR = undef;
	sysopen(AlertFILE, "$NfConf::PROFILESTATDIR/~$name/alert.dat", O_RDWR|O_CREAT) or
		$Log::ERROR = "Can't open alert data file for profile '$name': $!\n",
		return undef;

	flock AlertFILE, LOCK_EX;
	seek AlertFILE, 0,0;

	foreach my $line ( @{$$alertref{'description'}} ) {
		print AlertFILE "# $line\n";
	}
	foreach my $key ( @AlertKeys ) {
		next if $key eq 'description';
		next if $key eq 'condition';
		if ( !defined $$alertref{$key} ) {
			print AlertFILE "$key = \n";
		} else {
			print AlertFILE "$key = $$alertref{$key}\n";
		}
	}

	foreach my $condition ( @{$$alertref{'condition'}} ) {
		print AlertFILE "condition=$condition\n";
	}

	my $fpos = tell AlertFILE;
	truncate AlertFILE, $fpos;

	flock AlertFILE, LOCK_UN;
	if ( !close AlertFILE ) {
		$Log::ERROR = "Failed to close file on alert '$name': $!.",
		return undef;
	}

	return 1;

} # End of WriteAlert

sub InitRunInfo {
	my $name 	= shift;
	my $status	= shift;

	my %alertstatus = %AlertRunInfo;

	# Init all field required
	$alertstatus{'name'} 			= $name;
	$alertstatus{'created'} 		= time();
	$alertstatus{'trigger_status'} 	= $status;
	$alertstatus{'trigger_blocks'} 	= 0;
	$alertstatus{'trigger_info'} 	= '';

	for (my $i=0; $i < 10; $i++ ) {
		$alertstatus{'trigger_events'}[$i]	= 0;
	}

	for (my $i=0; $i < 288; $i++ ) {
		$alertstatus{'duration'}[$i] 		= 0;
		$alertstatus{'last'}{'flows'}[$i] 	= 0;
		$alertstatus{'last'}{'packets'}[$i] = 0;
		$alertstatus{'last'}{'bytes'}[$i] 	= 0;
	}
	for (my $i=0; $i < $LastEventNum; $i++ ) {
		$alertstatus{'last'}{'flows'}[$i] = 0;
		$alertstatus{'last'}{'packets'}[$i] = 0;
		$alertstatus{'last'}{'bytes'}[$i] = 0;
	}
	for (my $i=0; $i < 288; $i++ ) {
		$alertstatus{'last'}{'flows'}[$i] 	= 0;
		$alertstatus{'last'}{'packets'}[$i] = 0;
		$alertstatus{'last'}{'bytes'}[$i] 	= 0;
	}

	return StoreAlertStatus($name, \%alertstatus);

} # End of InitRunInfo

sub ResetAlertStatus {
	my $alert = shift;

	my $alertstatus = ReadAlertStatus($alert);
	if ( !defined $alertstatus ) {
		return;
	}
	$$alertstatus{'trigger_locks'} = 0;
	$$alertstatus{'cond_cnt'}	  = 0;
	$$alertstatus{'avg10m'}		  = { 'flows' => 0, 'packets' => 0, bytes => 0  };
	$$alertstatus{'avg30m'}		  = { 'flows' => 0, 'packets' => 0, bytes => 0  };
	$$alertstatus{'avg1h'}		  = { 'flows' => 0, 'packets' => 0, bytes => 0  };
	$$alertstatus{'avg6h'}		  = { 'flows' => 0, 'packets' => 0, bytes => 0  };
	$$alertstatus{'avg12h'}		  = { 'flows' => 0, 'packets' => 0, bytes => 0  };
	$$alertstatus{'avg24h'}		  = { 'flows' => 0, 'packets' => 0, bytes => 0  };

	return StoreAlertStatus($alert, $alertstatus);

} # End of ResetAlertStatus

sub ReadAlertStatus {
	my $alert = shift;

	my $alertstatus;
	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		$alertstatus = lock_retrieve "$NfConf::PROFILESTATDIR/~$alert/alert.status";
	};

	if ( my $err = $@ ) {
		syslog('err', "Error reading alert status of '$alert': $err\n");
		syslog('err', "Initialize alert status of '$alert' to defaults.\n");
		$err = InitRunInfo($alert, 0);
		if ( $err ne 'ok' ) {
			$alertstatus = undef;
		} else {
			eval {
				local $SIG{'__DIE__'} = 'DEFAULT';
				$alertstatus = lock_retrieve "$NfConf::PROFILESTATDIR/~$alert/alert.status";
			};
			if ( $err = $@ ) {
				syslog('err', "Error reading alert status of '$alert': $err\n");
				$alertstatus = undef;
			}
		}
	}

	return $alertstatus;

} # End of ReadAlertStatus

sub StoreAlertStatus {
	my $alert 		= shift;
	my $alertstatus = shift;


	syslog('debug', "Alert '$alert' Status: $$alertstatus{'trigger_status'}.\n");
	syslog('debug', "Alert '$alert' Blocks: $$alertstatus{'trigger_blocks'}.\n");
	syslog('debug', "Alert '$alert' Info  : $$alertstatus{'trigger_info'}.\n");

	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		lock_store $alertstatus, "$NfConf::PROFILESTATDIR/~$alert/alert.status";
	};

	if ( my $err = $@ ) {
		syslog('err', "Error store alert status of '$alert': $err\n");
		return $err;
	}

	return "ok";

} # End of StoreAlertStatus

sub UpdateAVG {
	my $alert		= shift;
	my $statinfo 	= shift;
	my $alertstatus = shift;
	my $t_unix		= shift;

	# Update stat values in alert status record
	if ( $$alertstatus{'updated'} == 0 ) {
		# first time update - initialize all values with first value
		syslog('info', "Initialize empty status record with first values\n");
		foreach my $type ( 'flows', 'packets', 'bytes' ) {
			for (my $i=0; $i < 288; $i++ ) {
				$$alertstatus{'last'}{$type}->[$i] = $$statinfo{$type};
			}
			$$alertstatus{'avg10m'}{$type} = $$statinfo{$type};
			$$alertstatus{'avg30m'}{$type} = $$statinfo{$type};
			$$alertstatus{'avg1h'}{$type}  = $$statinfo{$type};
			$$alertstatus{'avg6h'}{$type}  = $$statinfo{$type};
			$$alertstatus{'avg12h'}{$type} = $$statinfo{$type};
			$$alertstatus{'avg24h'}{$type} = $$statinfo{$type};
		}
	} else {
		# update all avg stats for this alert
		foreach my $type ( 'flows', 'packets', 'bytes' ) {
			pop @{$$alertstatus{'last'}{$type}};
			unshift @{$$alertstatus{'last'}{$type}}, $$statinfo{$type};

			my $sum = $$alertstatus{'last'}{$type}->[0] + $$alertstatus{'last'}{$type}->[1];
			$$alertstatus{'avg10m'}{$type} = int( $sum/2 );
			for (my $i=2; $i < 6; $i++ ) {
				$sum += $$alertstatus{'last'}{$type}->[$i];
			}
			$$alertstatus{'avg30m'}{$type} = int( $sum/6 );
			for (my $i=6; $i < 12; $i++ ) {
				$sum += $$alertstatus{'last'}{$type}->[$i];
			}
			$$alertstatus{'avg1h'}{$type} = int( $sum/12 );
			for (my $i=12; $i < 72; $i++ ) {
				$sum += $$alertstatus{'last'}{$type}->[$i];
			}
			$$alertstatus{'avg6h'}{$type} = int( $sum/72 );
			for (my $i=73; $i < 144; $i++ ) {
				$sum += $$alertstatus{'last'}{$type}->[$i];
			}
			$$alertstatus{'avg12h'}{$type} = int( $sum/144 );
			for (my $i=145; $i < 288; $i++ ) {
				$sum += $$alertstatus{'last'}{$type}->[$i];
			}
			$$alertstatus{'avg24h'}{$type} = int( $sum/288 );
		}
	}

	my $duration = 	($$statinfo{'last'} * 1000 + $$statinfo{'msec_last'}) - 
					($$statinfo{'first'} * 1000 + $$statinfo{'msec_first'});
	pop @{$$alertstatus{'duration'}};
	unshift @{$$alertstatus{'duration'}}, $duration;

	foreach my $type ( 'flows', 'packets', 'bytes' ) {
		my @vec = ( $$alertstatus{'last'}{$type}->[0],
					$$alertstatus{'avg10m'}{$type},
					$$alertstatus{'avg30m'}{$type},
					$$alertstatus{'avg1h'}{$type},
					$$alertstatus{'avg6h'}{$type},
					$$alertstatus{'avg12h'}{$type},
					$$alertstatus{'avg24h'}{$type},
		);

		NfSenRRD::UpdateDB("$NfConf::PROFILESTATDIR/~$alert/", "avg-$type", $t_unix, join(':', @DSlist), join(':', @vec));
		if ( $Log::ERROR ) {
			syslog('err', "ERROR Update alert RRD time: $Log::ERROR");
		}
	}

	$$alertstatus{'updated'} = $t_unix;

} # End of UpdateAVG

sub EvalCondition {
	my $alert_type	= shift;
	my $condition 	= shift;
	my $what_val 	= shift;
	my $alertstatus = shift;

## open LOG, ">>/dev/null";
## use Data::Dumper;
## print LOG "what_val array: 0 flows, 1 packets 2 bytes\n";
## print LOG Dumper($what_val);

	my @comp_types;
	$comp_types[0][0] = 0;
	$comp_types[0][1] = $$alertstatus{'avg10m'}{'flows'};
	$comp_types[0][2] = $$alertstatus{'avg30m'}{'flows'};
	$comp_types[0][3] = $$alertstatus{'avg1h'}{'flows'};
	$comp_types[0][4] = $$alertstatus{'avg6h'}{'flows'};
	$comp_types[0][5] = $$alertstatus{'avg12h'}{'flows'};
	$comp_types[0][6] = $$alertstatus{'avg24h'}{'flows'};

	$comp_types[1][0] = 0;
	$comp_types[1][1] = $$alertstatus{'avg10m'}{'packets'};
	$comp_types[1][2] = $$alertstatus{'avg30m'}{'packets'};
	$comp_types[1][3] = $$alertstatus{'avg1h'}{'packets'};
	$comp_types[1][4] = $$alertstatus{'avg6h'}{'packets'};
	$comp_types[1][5] = $$alertstatus{'avg12h'}{'packets'};
	$comp_types[1][6] = $$alertstatus{'avg24h'}{'packets'};

	$comp_types[2][0] = 0;
	$comp_types[2][1] = $$alertstatus{'avg10m'}{'bytes'};
	$comp_types[2][2] = $$alertstatus{'avg30m'}{'bytes'};
	$comp_types[2][3] = $$alertstatus{'avg1h'}{'bytes'};
	$comp_types[2][4] = $$alertstatus{'avg6h'}{'bytes'};
	$comp_types[2][5] = $$alertstatus{'avg12h'}{'bytes'};
	$comp_types[2][6] = $$alertstatus{'avg24h'}{'bytes'};

## print LOG "comp_types array: 0 flows, 1 packets 2 bytes\n";
## print LOG Dumper(@comp_types);

	# scale factors for k M G and T
	my @scale_factor = ( 1, 1000, 1000*1000, 1000*1000*1000, 1000*1000*1000*1000 );

	# match conditions
	my $condition_result = 0;
	my($op,$type,$comp,$comp_type,$stat_type,$comp_value,$scale) = split /:/, $condition;
	
## print LOG "Process condition: $op,$type,$comp,$comp_type,$stat_type,$comp_value,$scale\n";

	# prepare condition
	# this is rather complex with all variants possible
	# in the end we wan to compare $a cmp $b, so prepare $a and $b 
	my $a = $$what_val[$type];
	my $b;
	if ( $type > 2 ) {
		# this is a per/s compare. take $NfConf::CYCLETIME per slot to generate average
		if ( $type == 5 ) {
			# convert bytes to bits
			$b = 8 * $comp_types[$type-3][$comp_type]/$NfConf::CYCLETIME;
		} else {
			$b = $comp_types[$type-3][$comp_type]/$NfConf::CYCLETIME;
		}
	} else {
		# this is an absolute compare
		$b = $comp_types[$type][$comp_type];
	}
	my $value;
	if ( $scale == 5 ) {	# '%' range
		$value = int ( $comp_value * $b / 100); 
	} else {	# absolute range
		$value = $comp_value * $scale_factor[$scale];
	}
## print LOG "a: $a, b: $b value: $value\n";
	$condition_result = 0;
	if ( $comp == 2 ) { # outside
## print LOG "comp type = 2 'outside'\n";
		my $b1 = $b + $value;
		my $b2 = $b > $value ? $b - $value : 0;
		$condition_result = ($a > $b1) || ($a < $b2);
## print LOG "($a > $b1) || ($a < $b2) = $condition_result\n";
	} else {
		# comp '<' or '>'
		if ( $comp == 0 ) {	# '>'
			$b += $value;
## print LOG "comp type 0 '>'\n";
			$condition_result = $a > $b;
## print LOG "$a > $b = $condition_result\n";
		} elsif ( $comp == 1 ) { # '<'
## print LOG "comp type 1 '<'\n";
			if ( $comp_type == 0 ) {
				$b = $value;
			} else {
				# make sure value does not get < 0
				$b = $b > $value ? $b - $value : 0;
			}
			$condition_result = $a < $b;
## print LOG "$a < $b = $condition_result\n";
		}
	}
## close LOG;

	$condition_result = $condition_result ? 1 : 0;
	return($condition_result, $op);

} # End of EvalCondition

sub EvalStack {
	my $val_list = shift;
	my $opt_list = shift;

	# discard first for operator, push 2 (end of condition) to stack
	shift @{$opt_list};
	push @{$opt_list}, 2;

	my @val_stack;
	my @op_stack;

	my $done = 0;

	while ( !$done ) {
		my $value = shift @$val_list;
		my $op	  = shift @$opt_list;

		push @val_stack, $value;
		if ( defined $op_stack[0] && $op_stack[$#op_stack] == 0 ) {	# and
			pop @op_stack;
			my $a = pop @val_stack;
			my $b = pop @val_stack;
			push @val_stack, $a & $b ? 1 : 0;
		}
		if ( $op == 0 ) { # and 
			push @op_stack, $op;
		} else {
			if ( defined $op_stack[0] && $op_stack[$#op_stack] == 1 ) { # or 
				pop @op_stack;
				my $a = pop @val_stack;
				my $b = pop @val_stack;
				push @val_stack, $a | $b ? 1 : 0;
			}
			push @op_stack, $op;
		}
		$done = $op_stack[0] == 2; 	# we are done done
	}
	return $val_stack[$#op_stack];

} # End of EvalStack

sub GetTop1Stat {
	my $alert 	   = shift;
	my $t_iso 	   = shift;
	my $conditions = shift;

	my $file = "$NfConf::PROFILEDATADIR/~$alert/$alert/nfcapd.$t_iso";

	my @StatType = ( 
		'ip', 'srcip', 'dstip', 'port', 'srcport', 'dstport', 
		'as', 'srcas', 'dstas', 'if', 'inif', 'outif', 'proto'
	);

	my @StatOrderBy = ( 'flows', 'packets', 'bytes', 'pps', 'bps', 'bpp');

	my $stat = '';
	# prepare for each condition the required -s argument for nfdump
	foreach my $condition ( @{$conditions} ) {
		my($op,$type,$comp,$comp_type,$stat_type,$comp_value,$scale) = split /:/, $condition;
		$stat .= "-s $StatType[$stat_type]/$StatOrderBy[$type] ";
	}

	my $child_exit = 0;
	local $SIG{CHLD} = sub {
   		while ((my $waitedpid = waitpid(-1,WNOHANG)) > 0) {
       		$child_exit = $?;
       		my $exit_value  = $child_exit >> 8;
       		my $signal_num  = $child_exit & 127;
       		my $dumped_core = $child_exit & 128;
       		if ( $exit_value || $signal_num || $dumped_core ) {
           		syslog('err', "Alert Top 1 calculation failed: exit nfdump[$waitedpid] Exit: $exit_value, Signal: $signal_num, Core: $dumped_core");
       		}
   		}
	};
## print "ARG: $stat\n";
	my @output;
	if ( open NFDUMP, "$NfConf::PREFIX/nfdump -r $file -o pipe -q -n 1 $stat 2>&1|" ) {
		local $SIG{PIPE} = sub { syslog('err', "Pipe broke for nfprofile"); };
		@output = <NFDUMP>;
		close NFDUMP;    # SIGCHLD sets $child_exit
	}
    
	if ( $child_exit != 0 ) {
		syslog('err', "nfdump failed:\n");
		return undef;
	} 

	my $i = 0;
	my $statinfo;
	$$statinfo[0]{'flows'} 	 = 0;
	$$statinfo[0]{'packets'} = 0;
	$$statinfo[0]{'bytes'} 	 = 0;
	$$statinfo[0]{'pps'}     = 0;
	$$statinfo[0]{'bps'}     = 0;
	$$statinfo[0]{'bpp'}     = 0;
	foreach my $line ( @output ) {
		chomp $line;
		# each empty line marks the end of the current stat
		# prepare for next stat block. 
		if ( $line =~ /^$/ ) {
			$i++;
			$$statinfo[$i]{'flows'}   = 0;
			$$statinfo[$i]{'packets'} = 0;
			$$statinfo[$i]{'bytes'}   = 0;
			$$statinfo[$i]{'pps'}     = 0;
			$$statinfo[$i]{'bps'}     = 0;
			$$statinfo[$i]{'bpp'}     = 0;
			next;
		}
		my ($af, $_tmp) = split /\|/, $line, 2;
		if ( $af == AF_UNSPEC ) {
			my ($tstart, $tstart_msec, $tend, $tend_msec, $proto, $value, 
				$flows, $packets, $bytes, $pps, $bps, $bpp ) = split /\|/, $_tmp;
			$$statinfo[$i]{'flows'}	  = $flows;
			$$statinfo[$i]{'packets'} = $packets;
			$$statinfo[$i]{'bytes'}   = $bytes;
			$$statinfo[$i]{'pps'}     = $pps;
			$$statinfo[$i]{'bps'}     = $bps;
			$$statinfo[$i]{'bpp'}     = $bpp;
		
		} elsif ( $af == AF_INET || $af == AF_INET6) {
			my ($tstart, $tstart_msec, $tend, $tend_msec, $proto, $ip1, $ip2, $ip3, $ip4, 
				$flows, $packets, $bytes, $pps, $bps, $bpp ) = split /\|/, $_tmp;
			$$statinfo[$i]{'flows'}   = $flows;
			$$statinfo[$i]{'packets'} = $packets;
			$$statinfo[$i]{'bytes'}   = $bytes;
			$$statinfo[$i]{'pps'}     = $pps;
			$$statinfo[$i]{'bps'}     = $bps;
			$$statinfo[$i]{'bpp'}     = $bpp;
		} else {
			# schnabel
			syslog('err', "Unexpected nfdump line: '$line'\n");
		}
	}

	# the last array is an empty one - discard
	pop @{$statinfo};
	
	return $statinfo;

} # End of GetTop1Stat

sub GetAlertPluginCondition {
	my $alert 	   = shift;
	my $plugin 	   = shift;
	my $t_iso 	   = shift;

	my $file = "$NfConf::PROFILEDATADIR/~$alert/$alert/nfcapd.$t_iso";

	my $nfsend_socket;
	my %out_list;
	if ( $nfsend_socket = Nfcomm::nfsend_connect() ) {
		my $status = Nfcomm::nfsend_comm($nfsend_socket, 
			'get-alertcondition', { 
				'plugin' 	=> $plugin, 
				'alert' 	=> $alert, 
				'alertfile' => $file, 
				'timeslot' 	=> $t_iso }, \%out_list, { 'timeslot' => $t_iso } );
		if ( $status =~ /^ERR/ ) {
			syslog('err', "Failed to get alert condition fom plugin '$plugin': $status");
			$out_list{'condition'} = 0;
		}
	} else {
		syslog('err', "Can not connect to nfsend");
		return 0;
	}
	Nfcomm::nfsend_disconnect($nfsend_socket);

	return $out_list{'condition'} ? $out_list{'condition'} : 0;

} # End of GetAlertPluginCondition

sub ExecuteAction {
	my $alert		= shift;
	my $alertref 	= shift;
	my $alertstatus	= shift;
	my $timeslot	= shift;

	# send email 
	if ( ($$alertref{'action_type'} & 1) > 0 ) {
		syslog('debug', "alert '$alert' Send email to: $$alertref{'action_email'}");

		my @header = ( 	
			"From: $NfConf::MAIL_FROM",
			"To: $$alertref{'action_email'}",
			"Subject: $$alertref{'action_subject'}" 
		);

		my $mail_header = new Mail::Header( \@header ) ;

		my $mail_body_string = $NfConf::MAIL_BODY;
		# substitute all vars
		my %replace = ( 
			'alert'		=> 	$alert, 
			'timeslot'	=>	$timeslot,
		);
		foreach my $key ( keys %replace ) {
			$mail_body_string =~ s/\@$key\@/$replace{$key}/g;
		}

		my @mail_body = split /\n/, $mail_body_string;

		my $mail = new Mail::Internet( 
			Header => $mail_header, 
			Body   => \@mail_body,
		);

		my @sent_to = $mail->smtpsend( 
			Host     => $NfConf::SMTP_SERVER , 
			Hello    => $NfConf::SMTP_SERVER, 
			MailFrom => $NfConf::MAIL_FROM 
		);

		# Do we have failed receipients?
		my %_tmp;
		my @_recv = split /\s*,\s*/, $$alertref{'action_email'};
		@_tmp{@_recv} = 1;
		delete @_tmp{@sent_to};
		my @Failed = keys %_tmp;

		foreach my $rcpt ( @sent_to ) {
			syslog('info', "alert '$alert' : Successful sent mail to: '$rcpt'");
		}
		if ( scalar @Failed > 0 ) {
			foreach my $rcpt ( @Failed ) {
				syslog('err', "alert '$alert' : Failed to send alert email to: $rcpt");
			}
		} 

	}

	# execute system command
	if ( $NfConf::AllowsSystemCMD && (($$alertref{'action_type'} & 2) > 0) ) {
		my $pid;
		my @args;
		$args[0] = $$alertref{'action_system'};
		push @args, $alert;
		push @args, $timeslot;
		if ($pid = fork) {
			# register this pid, so SIGCHLD can handle that properly
			$main::PIDlist{$pid} = 1;
			syslog('info', "alert '$alert' : Execute system command[$pid]: $$alertref{'action_system'}");
		} else {
			exec { $args[0] } @args or
				syslog('err', "alert '$alert' : Failed to execute system command: $!");
		}
	}

	# call plugin
	if ( ($$alertref{'action_type'} & 4) > 0 ) {
		syslog('info', "alert '$alert' : Run action plugin $$alertref{'action_plugin'}");
		my $nfsend_socket;
		my %out_list;
		if ( $nfsend_socket = Nfcomm::nfsend_connect() ) {
			my $status = Nfcomm::nfsend_comm($nfsend_socket, 
				'run-alertaction', { 
					'plugin' 	=> $$alertref{'action_plugin'}, 
					'alert' 	=> $alert, 
					'timeslot' 	=> $timeslot }, \%out_list  );
			if ( $status =~ /^ERR/ ) {
				syslog('err', "Failed to run alert action plugin '$$alertref{'action_plugin'}': $status");
			} else {
				syslog('info', "alert '$alert' : Run action plugin completed");
			}
		} else {
			syslog('err', "Can not connect to nfsend");
			return 0;
		}
		Nfcomm::nfsend_disconnect($nfsend_socket);
	}

} # End of ExecuteAction

sub RunPeriodic {
	my $t_iso = shift;

	my $t_unix = NfSen::ISO2UNIX($t_iso);

	foreach my $alertname ( NfAlert::AlertList() ) {
		my %alertinfo = NfAlert::ReadAlert($alertname);
		if ( $alertinfo{'status'} ne 'enabled' ) {
			syslog('info', "alert '$alertname' skip: status: disabled");
			next;
		}

		syslog('info', "Process alert '$alertname'\n");
		my $alertstatus = ReadAlertStatus($alertname);
		if ( !defined $alertstatus ) {
			syslog('err', "alert '$alertname' skip: error reading alert status information");
			next;
		}

		delete $$alertstatus{'event_condition'};
		if ( $alertinfo{'type'} == 0 ) {
			# Conditions based on total flow summary:
			syslog('debug', "alert '$alertname': conditions based on total flow summary");
		} elsif ( $alertinfo{'type'} == 1 ) {
			# Conditions based on individual Top 10 statistics
			syslog('debug', "alert '$alertname': conditions based on individual Top 1 statistics");
		}  elsif ( $alertinfo{'type'} == 2 ) {
			syslog('debug', "alert '$alertname': conditions based on plugin");
		} else {
			syslog('err', "alert '$alertname' skip: Unknown type of alert: $alertinfo{'type'}");
			next;
		}

		my ($statinfo, $ret) = ReadStatInfo($alertname, $t_iso);
		if ( $ret ne "ok" ) {
			syslog('err', "Error reading statinfo of '$alertname': $ret");
			next;
		}

		# Update average stack
		UpdateAVG($alertname, $statinfo, $alertstatus, $t_unix);

		if ( ($$alertstatus{'trigger_status'} & 4) > 0 && $alertinfo{'trigger_type'} == 1 ) {
			# status trigger == fired, and once only allowed
			syslog('info', "alert '$alertname' skip: trigger already fired and once only permitted.");
			$$alertstatus{'trigger_info'} 	= "--";
			# reset trigger blocks, in case set. does not make sense here
			$$alertstatus{'trigger_blocks'}	= 0;
			StoreAlertStatus($alertname, $alertstatus);
			next;
		}

		# check for trigger blocks - if so decrement, report and continue
		if ( $$alertstatus{'trigger_blocks'} > 0 ) {
			syslog('info', "alert '$alertname' skip: trigger still blocked for $$alertstatus{'trigger_blocks'} cycles");
			$$alertstatus{'trigger_blocks'}--;
			my $blocks = $alertinfo{'trigger_blocks'} - $$alertstatus{'trigger_blocks'};
			$$alertstatus{'trigger_info'} = "$blocks/$alertinfo{'trigger_blocks'}";
			$$alertstatus{'trigger_status'} |= 9; # set bit3 to flag block
			StoreAlertStatus($alertname, $alertstatus);
			next;
		} 

		my $condition_result;
		if ( $alertinfo{'type'} == 2 ) {
			$condition_result = GetAlertPluginCondition($alertname, $alertinfo{'condition'}[0], $t_iso);
			$$alertstatus{'event_condition'}[0] = $condition_result > 0 ? 1 : 0;
		} else {
			if ( $alertinfo{'type'} == 1 ) {
				# overwrite statinfo of flow file with individual stats from Top 1 statistics
				$statinfo = GetTop1Stat($alertname, $t_iso, $alertinfo{'condition'});
			}
			my @val_stack;
			my @op_stack;
			my $i = 0;
			# eval all conditions
			foreach my $condition ( @{$alertinfo{'condition'}} ) {
				my @what_val;
	
				# Conditions based on total flow summary:
				# each conditions compares agains the total flow summary
				# therefore for each condition the same values from last stack
				if ( $alertinfo{'type'} == 0 ) {
					$what_val[0] = $$alertstatus{'last'}{'flows'}->[0];
					$what_val[1] = $$alertstatus{'last'}{'packets'}->[0];
					$what_val[2] = $$alertstatus{'last'}{'bytes'}->[0];
					# update per/s statistic
					# take $NfConf::CYCLETIME. this may vary from actual duration, which needs not to be exactly $NfConf::CYCLETIME
					# but for now stay with $NfConf::CYCLETIME
					$what_val[3] = $$alertstatus{'last'}{'flows'}->[0] / $NfConf::CYCLETIME;
					$what_val[4] = $$alertstatus{'last'}{'packets'}->[0] / $NfConf::CYCLETIME;
					$what_val[5] = 8 * $$alertstatus{'last'}{'bytes'}->[0] / $NfConf::CYCLETIME;
					#if ( $$alertstatus{'duration'}[0] != 0 ) {
						#$what_val[3] = $$alertstatus{'last'}{'flows'}->[0] / ($$alertstatus{'duration'}[0] / 1000);
						#$what_val[4] = $$alertstatus{'last'}{'packets'}->[0] / ($$alertstatus{'duration'}[0] / 1000);
						#$what_val[5] = 8 * $$alertstatus{'last'}{'bytes'}->[0] / ($$alertstatus{'duration'}[0] / 1000);
					#} else {
						#$what_val[3] = 0;
						#$what_val[4] = 0;
						#$what_val[5] = 0;
					#}
				}
	
				# Conditions based on individual Top 1 statistics
				# Each condition evaluated a statinfo record according the top 1 statistics
				if ( $alertinfo{'type'} == 1 ) {
					$what_val[0] = $$statinfo[$i]{'flows'};
					$what_val[1] = $$statinfo[$i]{'packets'};
					$what_val[2] = $$statinfo[$i]{'bytes'};
					$what_val[3] = $$statinfo[$i]{'pps'};
					$what_val[4] = $$statinfo[$i]{'bps'};
					$what_val[5] = $$statinfo[$i]{'bpp'};
				}
	
				my ($result, $op ) = EvalCondition($alertinfo{'type'}, $condition, \@what_val, $alertstatus);
				# push result of each condition on a val/opt stack
				push @val_stack, $result;
				push @op_stack, $op;
				syslog('info', "condition $i: evaluated to %s", $result ? 'True' : 'False');
				$$alertstatus{'event_condition'}[$i] = $result;
				$i++;
			}
			$condition_result = EvalStack(\@val_stack, \@op_stack);
		}
		$$alertstatus{'final_condition'} = $condition_result;

		syslog('debug', "Resulted condition: %s", $condition_result ? 'True' : 'False');


		if ( !$condition_result ) {
			# reset condition == true counter
			syslog('debug', "Alert '$alertname' condition == false\n");
			$$alertstatus{'cond_cnt'} = 0;
			# reset bit 1 for condition == true and bit 2 for trigger == true
			$$alertstatus{'trigger_status'} = 1; 
			StoreAlertStatus($alertname, $alertstatus);
			next;
		} 

		# here - the evaluated condition is true
		
		if ( ($$alertstatus{'trigger_status'} & 4) > 0 && $alertinfo{'trigger_type'} == 2 ) {
			# status trigger == fired, and once only allowed while condition == true
			syslog('info', "Alert '$alertname'  trigger suppressed while condition still true\n");
			$$alertstatus{'trigger_info'} = "--";
			$$alertstatus{'trigger_status'} |= 9; # set bit3 to flag block
			StoreAlertStatus($alertname, $alertstatus);
			next;
		}
		$$alertstatus{'trigger_status'} &= 3; 	# clear bit 2,3 to flags no block, no trigger

		# increment condition == true counter
		$$alertstatus{'cond_cnt'}++;
		syslog('debug', "Alert '$alertname' condition == true, condition counter: $$alertstatus{'cond_cnt'}\n");
		$$alertstatus{'trigger_status'} |= 2; # set bit 1 for condition == true
		
		if ( $$alertstatus{'cond_cnt'} < $alertinfo{'trigger_number'} ) {
			syslog('info', "Alert '$alertname' Condition count=$$alertstatus{'cond_cnt'}. required=$alertinfo{'trigger_number'} condition count not reached.\n");
			$$alertstatus{'trigger_info'} = "$$alertstatus{'cond_cnt'}/$alertinfo{'trigger_number'}";
			StoreAlertStatus($alertname, $alertstatus);
			next;
		} else {
			$$alertstatus{'trigger_info'} = "";
		}

		# 
		$$alertstatus{'cond_cnt'} = 0;
		$$alertstatus{'trigger_status'} |= 4; 	# set bit 2 for trigger fired
		$$alertstatus{'trigger_status'} &= 0xD;	# reset bit 1 for condition == true
		$$alertstatus{'trigger_info'} 	 = "";
		$$alertstatus{'trigger_blocks'} = $alertinfo{'trigger_blocks'};

		pop @{$$alertstatus{'trigger_events'}};
		unshift @{$$alertstatus{'trigger_events'}}, $t_unix;

		# trigger fired - execute action, if an action is defined
		if ( $alertinfo{'action_type'} ) {
			syslog('info', "Alert '$alertname' execute action\n");
			ExecuteAction($alertname, \%alertinfo, $alertstatus, $t_iso);
		} else {
			syslog('info', "Alert '$alertname' no action defined\n");
		}

		StoreAlertStatus($alertname, $alertstatus);
	} continue {
		unlink "$NfConf::PROFILEDATADIR/~$alertname/$alertname/nfcapd.$t_iso";
		syslog('debug', "Alert '$alertname' done.\n");
	}

} # End of RunPeriodic


#
# Entry points for nfsend. All subs have a socket and an opts field as input parameters
sub GetAllAlerts {
	my $socket	= shift;
	my $opts 	= shift;

	my @AllAlerts = AlertList();
	foreach my $alert ( @AllAlerts ) {
		my $alertstatus = ReadAlertStatus($alert);
		my $last = $$alertstatus{'trigger_events'}[0] ? localtime $$alertstatus{'trigger_events'}[0] : 'never';
		print $socket "_alertlist=$alert\n";
		print $socket "_alertstatus=$alert|$$alertstatus{'trigger_status'}|$$alertstatus{'trigger_info'}|$last\n";
	}
	foreach my $plugin ( keys %AlertPluginsCondition ) {
		print $socket "_alert_condition_plugin=$plugin\n";
	}
	foreach my $plugin ( keys %AlertPluginsAction ) {
		print $socket "_alert_action_plugin=$plugin\n";
	}
	print $socket $EODATA;

	if ( defined $Log::ERROR ) {
		print $socket "ERR $Log::ERROR\n";
	} else {
		print $socket "OK Alert Listing\n";
	}

} # End of GetAllAlerts

#
sub GetAlert {
	my $socket 	= shift;
	my $opts 	= shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		return "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print "ERR Illegal characters in alert name '$alert'!\n";
	}

	my %alertinfo = ReadAlert($alert);
	if ( $alertinfo{'status'} eq 'empty' ) {
		print $socket $EODATA;
		print $socket "ERR Alert '$alert': $Log::ERROR\n";
		return;
	}

	my $alertstatus = ReadAlertStatus($alert);
	if ( !defined $alertstatus ) {
		print $socket $EODATA;
		print $socket "ERR Failed to read alert status info\n";
		return;
	}

	my $last = $$alertstatus{'trigger_events'}[0] ? strftime("%F-%R", localtime $$alertstatus{'trigger_events'}[0]) : 'never';
	# raw output format
	foreach my $key ( keys %alertinfo ) {
		if ( ref $alertinfo{$key} eq 'ARRAY' ) {
			foreach my $line ( @{$alertinfo{$key}} ) {
				print $socket "_$key=$line\n";
			}
		} else  {
			if ( !defined $alertinfo{$key} ) {
				warn ".Undef for key '$key' in '$alert'";
			}
			print $socket  "$key=$alertinfo{$key}\n";
		}
	}
	print $socket  "trigger_status=$$alertstatus{'trigger_status'}\n";
	print $socket  "trigger_info=$$alertstatus{'trigger_info'}\n";
	print $socket  "final_condition=$$alertstatus{'final_condition'}\n";
	print $socket  "blocked=$$alertstatus{'trigger_blocks'}\n";
	print $socket  "updated=$$alertstatus{'updated'}\n";
	if ( $$alertstatus{'updated'} ) {
		print $socket  "updated_str=" . strftime("%F-%R", localtime $$alertstatus{'updated'}) . "\n";
	} else {
		print $socket  "updated_str=Never\n";
	}
	print $socket  "last_trigger=$last\n";
	
	foreach my $type ( 'flows', 'packets', 'bytes' ) {
		my @vec = ( $$alertstatus{'last'}{$type}->[0],
					$$alertstatus{'avg10m'}{$type},
					$$alertstatus{'avg30m'}{$type},
					$$alertstatus{'avg1h'}{$type},
					$$alertstatus{'avg6h'}{$type},
					$$alertstatus{'avg12h'}{$type},
					$$alertstatus{'avg24h'}{$type},
		);
		print $socket "last_$type=" . join(':', @vec) . "\n";
	}
	if ( exists $$alertstatus{'event_condition'} ) {
		print $socket "last_condition=" . join(':', @{$$alertstatus{'event_condition'}}) . "\n";
	}

	print $socket $EODATA;
	print $socket "OK Command completed\n";

} # End of GetAlert

#

#
sub GetAlertFilter {
	my $socket 	= shift;
	my $opts 	= shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		return "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print "ERR Illegal characters in alert name '$alert'!\n";
	}

	my $filter = ReadAlertFilter($alert);
	if ( !defined $filter ) {
		print $socket $EODATA;
		print $socket "ERR Alert filter: $Log::ERROR\n";
		return;
	}

	# 
	foreach my $line ( @{$filter} ) {
		print $socket "_alertfilter=$line\n";
	}

	print $socket $EODATA;
	print $socket "OK Command completed\n";

} # End of GetAlertFilter


sub AddAlert {
	my $socket = shift;
	my $opts   = shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in alert name '$alert'!\n";
		return;
	}

	if ( -f "$NfConf::PROFILESTATDIR/~$alert/alert.dat" ) {
		print $socket $EODATA;
		print $socket "ERR alert '$alert' already exists\n";
		return;
	}

	my $type = 0;
	if ( exists $$opts{'type'} ) {
		$type = $$opts{'type'};
		if ( $type !~ /^[012]$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$type' not a valid alert type\n";
			return;
		}
	} 

	my $status = 0;
	if ( exists $$opts{'status'} ) {
		$status = $$opts{'status'};
		if ( $status ne 'enabled' && $status ne 'disabled' ) {
			print $socket $EODATA;
			print $socket "ERR status '$status' not valid\n";
			return;
		}
	} 

	my $trigger_type = 0;
	if ( exists $$opts{'trigger_type'} ) {
		$trigger_type = $$opts{'trigger_type'};
		if ( $trigger_type !~ /^[0123]$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$trigger_type' not a valid trigger type\n";
			return;
		}
	} 

	my $trigger_number = 1;
	if ( exists $$opts{'trigger_number'} ) {
		$trigger_number = $$opts{'trigger_number'};
		if ( $trigger_number !~ /^[123456789]$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$trigger_number' not a valid trigger number\n";
			return;
		}
	} 

	my $trigger_blocks = 1;
	if ( exists $$opts{'trigger_blocks'} ) {
		$trigger_blocks = $$opts{'trigger_blocks'};
		if ( $trigger_blocks !~ /^\d$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$trigger_blocks' not a valid trigger blocks number\n";
			return;
		}
	} 

	my $action_type = 0;
	if ( exists $$opts{'action_type'} ) {
		$action_type = $$opts{'action_type'};
		if ( $action_type !~ /^[01234567]$/ ) {
			print $socket $EODATA;
			print $socket "ERR action_type '$action_type' not a valid alert action type\n";
			return;
		}
	} 

	my $action_email   = '';
	my $action_subject = 'Alert triggered';
	if ( ($action_type & 1) > 0 ) {
		if ( !defined $NfConf::MAIL_FROM ) {
			print $socket $EODATA;
			print $socket "ERR email 'From' address required in nfsen.conf file\n";
			return;
		}

		if ( !exists $$opts{'action_email'} ) {
			print $socket $EODATA;
			print $socket "ERR action_email required for action_type=1\n";
			return;
		}

		$action_email = $$opts{'action_email'};
		$action_email =~ s/^\s+//;
		$action_email =~ s/\s$//;
		foreach my $email_addr ( split /\s*,\s*/, $action_email ) {
			if ( !NfSen::ValidEmail($email_addr)) {
				print $socket $EODATA;
				print $socket "ERR action_email '$email_addr' not a valid email address\n";
				return;
			}
		}

		if ( exists $$opts{'action_subject'} ) {
			$action_subject = $$opts{'action_subject'};
			if ( $action_subject ne "" && $action_subject !~ /[\s!-~]+/ ) {
				print $socket $EODATA;
				print $socket "ERR action_subject '$action_subject' contains illegal characters\n";
				return;
			}
		}
	}
	
	my $action_system = '';
	if ( ($action_type & 2 ) > 0) {
		if ( !$NfConf::AllowsSystemCMD ) {
			print $socket $EODATA;
			print $socket "ERR action_system: Option not enabled.\n";
			return;
		}
		if ( !exists $$opts{'action_system'} ) {
			print $socket $EODATA;
			print $socket "ERR action_system required for action_type=2\n";
			return;
		}
		$action_system = $$opts{'action_system'};
		$action_system =~ s/^\s+//;
		$action_system =~ s/\s+$//;
		if ( $action_system !~ /[\s!-~]+/ ) {
			print $socket $EODATA;
			print $socket "ERR action_system '$action_system' empty or contains illegal characters\n";
			return;
		}
		if ( !-x $action_system ) {
			print $socket $EODATA;
			print $socket "ERR action_system '$action_system' not an executable file\n";
			return;
		}
	}

	my $action_plugin = '';
	if ( ($action_type & 4 ) > 0) {
		if ( !exists $$opts{'action_plugin'} ) {
			print $socket $EODATA;
			print $socket "ERR action_plugin required for action_type=4\n";
			return;
		}
		$action_plugin = $$opts{'action_plugin'};
		if ( $action_plugin !~ /[\s!-~]+/ ) {
			print $socket $EODATA;
			print $socket "ERR action_plugin '$action_plugin' empty or contains illegal characters\n";
			return;
		}

		if ( ! exists $AlertPluginsAction{$action_plugin} ) {
			print $socket $EODATA;
			print $socket "ERR action_plugin '$action_plugin' is not a plugin or has no alert_action function\n";
			return;
		}

	}

	# get all conditions
	if ( !exists $$opts{'condition'} ) {
		print $socket $EODATA;
		print $socket "ERR At least one condition needed for alert\n";
		return;
	}
	my $conditions = $$opts{'condition'};
	if ( $type == 2 ) {
		# condition based on plugin
		if ( scalar @$conditions != 1 ) {
			print $socket $EODATA;
			print $socket "ERR Exactly one plugin required for plugin based condition\n";
			return;
		}
		my $plugin = $$conditions[0];
		if ( !exists $AlertPluginsCondition{$plugin} ) {
			print $socket $EODATA;
			print $socket "ERR Plugin '$plugin' does not exists or has no alert condition function\n";
			return;
		}
	} else {
		foreach my $condition ( @$conditions ) {
			my @_tmp = split /:/, $condition;
			if ( scalar @_tmp != 7 ) {
				print $socket $EODATA;
				print $socket "ERR Wrong number of attributes for condition '$condition'\n";
				return;
			}
			# @max_attribute_val contains the max number of indices which must match the appropriat array in alerting.php
			my @max_attribute_val;
			if ( $type == 0 ) {
				@max_attribute_val = ( 1, 5, 2, 6, 0, 0, 5);
			} else {
				@max_attribute_val = ( 1, 5, 1, 0, 12, 0, 4);
			}
			for ( my $i=0; $i < 7; $i++ ) {
				if ( $max_attribute_val[$i] && ($_tmp[$i] > $max_attribute_val[$i]) ) {
					print $socket $EODATA;
					print $socket "ERR Attribute $i value $_tmp[$i] > $max_attribute_val[$i] in condition '$condition'\n";
					return;
				}
			}
		}
	}

	# channel list for alert
	my $channellist;
	my %liveprofile = NfProfile::ReadProfile('live', '.');
	if ( exists $$opts{'channellist'} ) {
		$channellist = $$opts{'channellist'};
		while ( $channellist =~ s/\|\|/|/g ) {;}
		$channellist =~ s/^\|//;
		$channellist =~ s/\|$//;
		my @_list = split /\|/, $channellist;
		foreach my $source ( @_list ) {
			if ( !exists $liveprofile{'channel'}{$source} ) {
				print $socket $EODATA;
				print $socket "ERR source '$source' does not exist in profile live\n";
				return;
			}
		}
	} else {
		$channellist = join '|', keys %{$liveprofile{'channel'}};
	}

	# Alert filter:
	my $filter = [];
	if ( exists $$opts{'filter'} ) {
		$filter = $$opts{'filter'};
		# convert a one line filter
		if ( ref $filter ne "ARRAY" ) {
			$filter = [ "$filter" ];
		}
	} elsif ( exists $$opts{'filterfile'} ) {
		open(FILTER, $$opts{'filterfile'} ) or
			syslog('err', "Can't open filter file '$filter': $!"),
			print $socket $EODATA;
			print $socket "ERR Can't open filter file '$filter': $!\n",
			return;
		@$filter = <FILTER>;
		close FILTER;
	}
	if ( scalar @$filter == 0 ) {
		push @$filter, "not any\n";
	}
	my %out = NfSen::VerifyFilter($filter);
	if ( $out{'exit'} > 0 ) {
		print $socket $EODATA;
		print $socket "ERR Filter syntax error: ", join(' ', $out{'nfdump'}), "\n";
		return;
	}

	# Do the work now:
	umask 0002;
	my @dirs;
	push @dirs, "$NfConf::PROFILESTATDIR";
	# if stat and data dirs differ
	if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
		push @dirs, "$NfConf::PROFILEDATADIR";
	}

	foreach my $dir ( @dirs ) {
		if ( !mkdir "$dir/~$alert" ) {
			my $err = $!;
			syslog("err", "Can't create alert directory '$dir/$alert': $err");
			print $socket $EODATA;
			print $socket "ERR Can't create alert directory '$dir/$alert': $err!\n";
			return;
		}
	}
	if ( !mkdir "$NfConf::PROFILEDATADIR/~$alert/$alert" ) {
		my $err = $!;
		syslog("err", "Can't create alert directory '$NfConf::PROFILEDATADIR/~$alert/$alert': $err");
		print $socket $EODATA;
		print $socket "ERR Can't create alert directory '$NfConf::PROFILEDATADIR/~$alert/$alert': $err!\n";
		return;
	}

	# setup alert filter
	my $filterfile = "$NfConf::PROFILESTATDIR/~$alert/$alert-filter.txt";

	if ( !open(FILTER, ">$filterfile" ) ) {
		my $err = $!;
		print $socket $EODATA;
		print $socket "ERR Can't open filter file '$filterfile': $err\n";
		foreach my $dir ( @dirs ) {
			rmdir $dir;
		}
		return;
	}

	print FILTER map "$_\n", @$filter;
	close FILTER;

	# Convert a one line description
	if ( exists $$opts{'description'} && ref $$opts{'description'} ne "ARRAY" ) {
		$$opts{'description'} = [ "$$opts{'description'}" ];
	}
	my %alertinfo;
	$alertinfo{'description'}	= exists $$opts{'description'} ? $$opts{'description'} : \@AlertTag;
	$alertinfo{'name'}			= $alert;
	
	$alertinfo{'type'}			= $type;
	$alertinfo{'channellist'}	= $channellist;

	$alertinfo{'trigger_type'}	= $trigger_type;
	$alertinfo{'trigger_number'}= $trigger_number;
	$alertinfo{'trigger_blocks'}= $trigger_blocks;

	$alertinfo{'action_type'}	= $action_type;
	$alertinfo{'action_email'}	= $action_email;
	$alertinfo{'action_subject'}= $action_subject;
	$alertinfo{'action_system'}	= $action_system;
	$alertinfo{'action_plugin'}	= $action_plugin;
	$alertinfo{'condition'}		= $conditions;

	# status new
	$alertinfo{'status'}		= $status;

	# Version of alert
	$alertinfo{'version'}		= $ALERT_VERSION;

	if ( !WriteAlert(\%alertinfo) ) {
		syslog('err', "Error writing alert '$alert': $Log::ERROR");
		print $socket $EODATA;
		print $socket "ERR writing alert '$alert': $Log::ERROR\n";
		# Even if we could not write the alert, try to delete the remains anyway
		foreach my $dir ( @dirs ) {
			my $command = "/bin/rm -rf $dir/.~$alert &";
			system($command);
		}
	}
	
	InitRunInfo($alert, $status eq 'enabled' ? 1 : 0);
	foreach my $type ( 'flows', 'packets', 'bytes' ) {
		NfSenRRD::SetupAlertRRD("$NfConf::PROFILESTATDIR/~$alert/", "avg-$type", $liveprofile{'tend'} - $NfConf::CYCLETIME, \@DSlist);
    	if ( defined $Log::ERROR ) {
			print $socket $EODATA;
        	print $socket "ERR Creating alert RRD for '$alert' failed: $Log::ERROR\n";
			foreach my $dir ( @dirs ) {
				my $command = "/bin/rm -rf $dir/.~$alert &";
				system($command);
			}
    	}
    }

	print $socket $EODATA;
	print $socket "OK alert added\n";

} # End of AddAlert

sub ModifyAlert {
	my $socket = shift;
	my $opts   = shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing alert name";
		return;
	} 

	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in alert name '$alert'!\n";
		return;
	}

	if ( ! -f "$NfConf::PROFILESTATDIR/~$alert/alert.dat" ) {
		print $socket $EODATA;
		print $socket "ERR alert '$alert' does not exists\n";
		return;
	}

	my %alertinfo = ReadAlert($alert);
	if ( $alertinfo{'status'} eq 'empty' ) {
		print $socket $EODATA;
		print $socket "ERR Alert '$alert': $Log::ERROR\n";
		return;
	}

	my $alertstatus = ReadAlertStatus($alert);
	if ( !defined $alertstatus ) {
		print $socket $EODATA;
		print $socket "ERR Failed to read alert status info\n";
		return;
	}

	if ( exists $$opts{'type'} ) {
		my $type = $$opts{'type'};
		if ( $type !~ /^[012]$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$type' not a valid alert type\n";
			return;
		}
		if ( $type != $alertinfo{'type'} ) {
			ResetAlertStatus($alert);
		}
		$alertinfo{'type'} = $type;
		# when changing the alert type - current conditions do not make sense any more
		delete $alertinfo{'condition'};
		delete $$alertstatus{'event_condition'};
	} 

	if ( exists $$opts{'status'} ) {
		my $status = $$opts{'status'};
		if ( $status ne 'enabled' && $status ne 'disabled' ) {
			print $socket $EODATA;
			print $socket "ERR status '$status' not valid\n";
			return;
		}
		$alertinfo{'status'} = $status;
	} 

	if ( exists $$opts{'trigger_type'} ) {
		my $trigger_type = $$opts{'trigger_type'};
		if ( $trigger_type !~ /^[0123]$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$trigger_type' not a valid trigger type\n";
			return;
		}
		$alertinfo{'trigger_type'} = $trigger_type;
	} 

	if ( exists $$opts{'trigger_number'} ) {
		my $trigger_number = $$opts{'trigger_number'};
		if ( $trigger_number !~ /^[123456789]$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$trigger_number' not a valid trigger number\n";
			return;
		}
		$alertinfo{'trigger_number'} = $trigger_number;
	} 

	if ( exists $$opts{'trigger_blocks'} ) {
		my $trigger_blocks = $$opts{'trigger_blocks'};
		if ( $trigger_blocks !~ /^[0123456789]$/ ) {
			print $socket $EODATA;
			print $socket "ERR type '$trigger_blocks' not a valid trigger blocks number\n";
			return;
		}
		$alertinfo{'trigger_blocks'} = $trigger_blocks;
	} 

	if ( exists $$opts{'action_type'} ) {
		my $action_type = $$opts{'action_type'};
		if ( $action_type !~ /^[01234567]$/ ) {
			print $socket $EODATA;
			print $socket "ERR action_type '$action_type' not a valid alert action type\n";
			return;
		}
		$alertinfo{'action_type'} = $action_type;
	} 

	if ( ($alertinfo{'action_type'} & 1) > 0 && exists $$opts{'action_subject'} ) {
		my $action_subject = $$opts{'action_subject'};
		if ( $action_subject ne "" && $action_subject !~ /[\s!-~]+/ ) {
			print $socket $EODATA;
			print $socket "ERR action_subject '$action_subject' contains illegal characters\n";
			return;
		}
		$alertinfo{'action_subject'} = $action_subject;
	}

	if ( ($alertinfo{'action_type'} & 1) > 0 && exists $$opts{'action_email'} ) {
		if ( !defined $NfConf::MAIL_FROM ) {
			print $socket $EODATA;
			print $socket "ERR email 'From' address required in nfsen.conf file\n";
			return;
		}

		my $action_email = $$opts{'action_email'};
		$action_email =~ s/^\s+//;
		$action_email =~ s/\s$//;
		foreach my $email_addr ( split /\s*,\s*/, $action_email ) {
			if ( !NfSen::ValidEmail($email_addr) ) {
				print $socket $EODATA;
				print $socket "ERR action_email '$email_addr' not a valid email address\n";
				return;
			}	
		}
		$alertinfo{'action_email'} = $action_email;
		if ( $alertinfo{'action_subject'} eq "" ) {
			$alertinfo{'action_subject'} = "Alert triggered";
		}
	}


	if ( ($alertinfo{'action_type'} & 2) > 0  && exists $$opts{'action_system'} ) {
		if ( !$NfConf::AllowsSystemCMD ) {
			print $socket $EODATA;
			print $socket "ERR action_system: Option not enabled.\n";
			return;
		}
		my $action_system = $$opts{'action_system'};
		$action_system =~ s/^\s+//;
		$action_system =~ s/\s+$//;
		if ( $action_system !~ /[\s!-~]+/ ) {
			print $socket $EODATA;
			print $socket "ERR action_system '$action_system' empty or contains illegal characters\n";
			return;
		}
		if ( !-x $action_system ) {
			print $socket $EODATA;
			print $socket "ERR action_system '$action_system' not an executable file\n";
			return;
		}
		$alertinfo{'action_system'} = $action_system;
	}

	if ( ($alertinfo{'action_type'} & 4) > 0  && exists $$opts{'action_plugin'} ) {
		my $action_plugin = $$opts{'action_plugin'};
		if ( $action_plugin !~ /[\s!-~]+/ ) {
			print $socket $EODATA;
			print $socket "ERR action_plugin '$action_plugin' empty or contains illegal characters\n";
			return;
		}

		if ( ! exists $AlertPluginsAction{$action_plugin} ) {
			print $socket $EODATA;
			print $socket "ERR action_plugin '$action_plugin' is not a plugin or has no alert_action function\n";
			return;
		}
		$alertinfo{'action_plugin'} = $action_plugin;
	}

	# get all conditions
	if ( exists $$opts{'condition'} ) {
		my $conditions = $$opts{'condition'};
		if ( $alertinfo{'type'} == 2 ) {
			# condition based on plugin
			if ( scalar @$conditions != 1 ) {
				print $socket $EODATA;
				print $socket "ERR Exactly one plugin required for plugin based condition\n";
				return;
			}
			my $plugin = $$conditions[0];
			if ( !exists $AlertPluginsCondition{$plugin} ) {
				print $socket $EODATA;
				print $socket "ERR Plugin '$plugin' does not exists or has no alert condition function\n";
				return;
			}
	
		} else {
			foreach my $condition ( @$conditions ) {
				my @_tmp = split /:/, $condition;
				if ( scalar @_tmp != 7 ) {
					print $socket $EODATA;
					print $socket "ERR Wrong number of attributes for condition '$condition'\n";
					return;
				}
				my @max_attribute_val;
				if ( $alertinfo{'type'} == 0 ) {
					@max_attribute_val = ( 1, 5, 2, 6, 0, 0, 5);
				} else {
					@max_attribute_val = ( 1, 5, 1, 0, 12, 0, 4);
				}
				for ( my $i=0; $i < 7; $i++ ) {
					if ( $max_attribute_val[$i] && ($_tmp[$i] > $max_attribute_val[$i]) ) {
						print $socket $EODATA;
						print $socket "ERR Attribute $i value $_tmp[$i] > $max_attribute_val[$i] in condition '$condition'\n";
						return;
					}
				}
			}
		}
		$alertinfo{'condition'}		= $conditions;
		delete $$alertstatus{'event_condition'};
	}

	if ( ($alertinfo{'type'} == 0 || $alertinfo{'type'} == 1) && !exists $alertinfo{'condition'} ) {
		print $socket $EODATA;
		print $socket "ERR At least one condition needed for alert\n";
		return;
	}
	if ( ($alertinfo{'action_type'} & 2) > 0 && !exists $alertinfo{'action_system'} ) {
		print $socket $EODATA;
		print $socket "ERR Action type=3 needs a valid system command\n";
		return;
	}
	# channel list for alert
	if ( exists $$opts{'channellist'} ) {
		my %liveprofile = NfProfile::ReadProfile('live', '.');
		my $channellist = $$opts{'channellist'};
		while ( $channellist =~ s/\|\|/|/g ) {;}
		$channellist =~ s/^\|//;
		$channellist =~ s/\|$//;
		my @_list = split /\|/, $channellist;
		foreach my $source ( @_list ) {
			if ( !exists $liveprofile{'channel'}{$source} ) {
				print $socket $EODATA;
				print $socket "ERR source '$source' does not exist in profile live\n";
				return;
			}
		}
		$alertinfo{'channellist'}	= $channellist;
	} 

	# Alert filter:
	my $filter = [];
	if ( exists $$opts{'filter'} ) {
		$filter = $$opts{'filter'};
		# convert a one line filter
		if ( ref $filter ne "ARRAY" ) {
			$filter = [ "$filter" ];
		}
	} 
	if ( exists $$opts{'filterfile'} ) {
		open(FILTER, $$opts{'filterfile'} ) or
			syslog('err', "Can't open filter file '$filter': $!"),
			print $socket $EODATA;
			print $socket "ERR Can't open filter file '$filter': $!\n",
			return;
		@$filter = <FILTER>;
		close FILTER;
	}
	if ( scalar @$filter > 0 ) {
		my %out = NfSen::VerifyFilter($filter);
		if ( $out{'exit'} > 0 ) {
			print $socket $EODATA;
			print $socket "ERR Filter syntax error: ", join(' ', $out{'nfdump'}), "\n";
			return;
		}
		# setup alert filter
		my $filterfile = "$NfConf::PROFILESTATDIR/~$alert/$alert-filter.txt";

		if ( !open(FILTER, ">$filterfile" ) ) {
			my $err = $!;
			print $socket $EODATA;
			print $socket "ERR Can't open filter file '$filterfile': $err\n";
			return;
		}
	
		print FILTER map "$_\n", @$filter;
		close FILTER;

	}

	if ( $alertinfo{'status'} eq 'enabled' ) {
		$$alertstatus{'trigger_status'} = 1;	# set enable
		$$alertstatus{'trigger_blocks'}	= 0;
		$$alertstatus{'cond_cnt'} 		= 0;
	} else {
		$$alertstatus{'trigger_status'} = 0;	# clear enable
		delete $$alertstatus{'event_condition'};
	}
	StoreAlertStatus($alert, $alertstatus);

	if ( !WriteAlert(\%alertinfo) ) {
		syslog('err', "Error writing alert '$alert': $Log::ERROR");
		print $socket $EODATA;
		print $socket "ERR writing alert '$alert': $Log::ERROR\n";
		return;
	}
	
	print $socket $EODATA;
	print $socket "OK alert modified\n";

} # End of ModifyAlert


sub DeleteAlert {
	my $socket = shift;
	my $opts   = shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		return "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print "ERR Illegal characters in alert name '$alert'!\n";
	}

	if ( ! -f "$NfConf::PROFILESTATDIR/~$alert/alert.dat" ) {
		print $socket $EODATA;
		print $socket "ERR alert '$alert' does not exists\n";
		return;
	}


	my @dirs;
	push @dirs, "$NfConf::PROFILESTATDIR";
	if ( "$NfConf::PROFILESTATDIR" ne "$NfConf::PROFILEDATADIR" ) {
		push @dirs, "$NfConf::PROFILEDATADIR";
	}
	foreach my $dir ( @dirs ) {
		if ( !Nfsync::semnowait() ) {
			print $socket $EODATA;
			print $socket "ERR Can not delete the alert while a periodic update is in progress. Try again later.\n";
			return;
		}

		if ( !rename "$dir/~$alert", "$dir/.~$alert" ) {
			Nfsync::semsignal();
			print $socket $EODATA;
			print $socket "ERR Failed to rename alert '$alert' in order to delete: $!\n";
			return;
		} else {
			Nfsync::semsignal();
		}

		my $command = "/bin/rm -rf $dir/.~$alert &";
		system($command);
		if ( defined $main::child_exit && $main::child_exit != 0 ) {
			syslog('err', "Failed to execute command: $!\n");
			syslog('err', "system command was: '$command'\n");
		} 
	}

	print $socket $EODATA;
	print $socket "OK Alert '$alert' deleted.\n";

} # End of DeleteAlert

sub ArmAlert {
	my $socket = shift;
	my $opts   = shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		print "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print "ERR Illegal characters in alert name '$alert'!\n";
	}

	if ( ! -f "$NfConf::PROFILESTATDIR/~$alert/alert.dat" ) {
		print $socket $EODATA;
		print $socket "ERR alert '$alert' does not exists\n";
		return;
	}

	my %alertinfo = ReadAlert($alert);
	if ( $alertinfo{'status'} eq 'empty' ) {
		print $socket $EODATA;
		print $socket "ERR Alert '$alert': $Log::ERROR\n";
		return;
	}

	if ( $alertinfo{'trigger_type'} != 1 ) {
		print $socket $EODATA;
		print $socket "ERR Alert '$alert' trigger type $alertinfo{'trigger_type'} can not be armed manually\n";
		return;
	}

	my $alertstatus = ReadAlertStatus($alert);
	if ( !defined $alertstatus ) {
		print $socket $EODATA;
		print $socket "ERR Failed to read alert status info\n";
		return;
	}

	$$alertstatus{'trigger_status'} &= 1; 	
	$$alertstatus{'trigger_blocks'} = 0; 	
	$$alertstatus{'trigger_info'} 	= 0; 	
	StoreAlertStatus($alert, $alertstatus);

	print $socket $EODATA;
	print $socket "OK Alert '$alert' armed.\n";

} # End of DeleteAlert

sub GetAlertGraph {
	my $socket 	= shift;
	my $opts 	= shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		print "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print "ERR Illegal characters in alert name '$alert'!\n";
		return;
	}

	if ( ! -f "$NfConf::PROFILESTATDIR/~$alert/alert.dat" ) {
		print $socket $EODATA;
		print $socket "ERR alert '$alert' does not exists\n";
		return;
	}

	if ( !exists $$opts{'arg'} ) {
		print $socket $EODATA;
		print $socket "ERR details argument list required.\n";
		return;
	}
	my $detailargs = $$opts{'arg'};
	push @{$detailargs}, join ':', @DSlist;
	push @{$detailargs}, 576;
	push @{$detailargs}, 200;

	my $alertstatus = ReadAlertStatus($alert);
	if ( scalar @{$$alertstatus{'trigger_events'}} == 0 ) {
		push @{$detailargs}, 0;
	} else {
		push @{$detailargs}, join ':', @{$$alertstatus{'trigger_events'}};
	}

	my $ret = NfSenRRD::GenAlertGraph($alert, $detailargs);
	if ( $ret ne "ok" ) {
		syslog('err', "Error generating details graph: $ret");
		print $socket $EODATA;
		print $socket "ERR generating details graph: $ret\n";
	}

} # End of GetAlertGraph

sub CleanAlerts {
	foreach my $alertname ( AlertList() ) {
		opendir(PROFILEDIR, "$NfConf::PROFILEDATADIR/~$alertname/$alertname/" ) or
		syslog('err', "Can't open alert data directory: '$NfConf::PROFILEDATADIR/~$alertname/$alertname/': $!");
		my @OldFlowFiles = grep { $_ =~ /nfcapd/ || $_ =~ /nfprofile/ } 
							readdir(PROFILEDIR);
		closedir PROFILEDIR;
		
		foreach my $filename (@OldFlowFiles) { 
			unlink "$NfConf::PROFILEDATADIR/~$alertname/$alertname/$filename";
		}

	}
} # End of CleanAlerts
1;
