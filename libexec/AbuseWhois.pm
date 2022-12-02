#!%%PERL%%
#
#  Copyright (c) 2004, Peter Haag
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
#   * Neither the name of the author nor the names of its contributors may be
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
#  $Id: AbuseWhois.pm 62 2014-04-07 17:22:03Z peter $
#
#  $LastChangedRevision: 62 $


package AbuseWhois;

use strict;
use warnings;
use Socket;
use Socket6 qw(inet_pton);
use Sys::Syslog; 
use IO::Socket::INET;
use Log;

# Regex for IPv6 validation
my $IPv4 = "((25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2}))";
my $G = "[0-9a-fA-F]{1,4}";

my @tail = ( ":",
         "(:($G)?|$IPv4)",
             ":($IPv4|$G(:$G)?|)",
             "(:$IPv4|:$G(:$IPv4|(:$G){0,2})|:)",
         "((:$G){0,2}(:$IPv4|(:$G){1,2})|:)",
         "((:$G){0,3}(:$IPv4|(:$G){1,2})|:)",
         "((:$G){0,4}(:$IPv4|(:$G){1,2})|:)" );

my $IPv6_re = $G;
$IPv6_re = "$G:($IPv6_re|$_)" for @tail;
$IPv6_re = qq/:(:$G){0,5}((:$G){1,2}|:$IPv4)|$IPv6_re/;
$IPv6_re =~ s/\(/(?:/g;
$IPv6_re = qr/$IPv6_re/;


# Lookup functions depending on regional Internet registry
my %RegistryLookup = (
	"ARNIN" 	=> \&do_ARNIN,
	"APNIC" 	=> \&do_APNIC,
	"LACNIC" 	=> \&do_LACNIC,
	"RIPE" 		=> \&do_RIPE,
	"AFRINIC" 	=> \&do_AFRINIC,
);

# hmm .. do we have lookups on these ?? - not sure
#	"JAPANI" 	=> "whois.v6nic.net",
#	"JNIC" 		=> "whois.nic.ad.jp",

# Local Logging functions
sub LogError($) {
	my $message = shift;

	syslog("err","$message");

} # End of LogError

sub LogDebug($) {
	my $message = shift;

	syslog("debug","$message");

} # End of LogDebug

sub get_countryname($) {
	my $tld = shift;

	my %TLD_map = (
		"AC" => "Ascension Island",
		"AD" => "Andorra",
		"AE" => "United Arab Emirates",
		"AF" => "Afghanistan",
		"AG" => "Antigua and Barbuda",
		"AI" => "Anguilla",
		"AL" => "Albania",
		"AM" => "Armenia",
		"AN" => "Netherlands Antilles",
		"AO" => "Angola",
		"AQ" => "Antarctica",
		"AR" => "Argentina",
		"AS" => "American Samoa",
		"AT" => "Austria",
		"AU" => "Australia",
		"AW" => "Aruba",
		"AX" => "Aland Islands",
		"AZ" => "Azerbaijan",
		"BA" => "Bosnia and Herzegovina",
		"BB" => "Barbados",
		"BD" => "Bangladesh",
		"BE" => "Belgium",
		"BF" => "Burkina Faso",
		"BG" => "Bulgaria",
		"BH" => "Bahrain",
		"BI" => "Burundi",
		"BJ" => "Benin",
		"BL" => "Saint Barthelemy",
		"BM" => "Bermuda",
		"BN" => "Brunei Darussalam",
		"BO" => "Bolivia",
		"BR" => "Brazil",
		"BS" => "Bahamas",
		"BT" => "Bhutan",
		"BV" => "Bouvet Island",
		"BW" => "Botswana",
		"BY" => "Belarus",
		"BZ" => "Belize",
		"CA" => "Canada",
		"CC" => "Cocos",
		"CD" => "The Democratic Republic of the Congo",
		"CF" => "Central African Republic",
		"CG" => "Congo",
		"CH" => "Switzerland",
		"CI" => "Cote d'Ivoire",
		"CK" => "Cook Islands",
		"CL" => "Chile",
		"CM" => "Cameroon",
		"CN" => "China",
		"CO" => "Colombia",
		"CR" => "Costa Rica",
		"CU" => "Cuba",
		"CV" => "Cape Verde",
		"CX" => "Christmas Island",
		"CY" => "Cyprus",
		"CZ" => "Czech Republic",
		"DE" => "Germany",
		"DJ" => "Djibouti",
		"DK" => "Denmark",
		"DM" => "Dominica",
		"DO" => "Dominican Republic",
		"DZ" => "Algeria",
		"EC" => "Ecuador",
		"EE" => "Estonia",
		"EG" => "Egypt",
		"EH" => "Western Sahara",
		"ER" => "Eritrea",
		"ES" => "Spain",
		"ET" => "Ethiopia",
		"EU" => "European Union",
		"FI" => "Finland",
		"FJ" => "Fiji",
		"FK" => "Falkland Islands",
		"FM" => "Federated States of Micronesia",
		"FO" => "Faroe Islands",
		"FR" => "France",
		"GA" => "Gabon",
		"GB" => "United Kingdom",
		"GD" => "Grenada",
		"GE" => "Georgia",
		"GF" => "French Guiana",
		"GG" => "Guernsey",
		"GH" => "Ghana",
		"GI" => "Gibraltar",
		"GL" => "Greenland",
		"GM" => "Gambia",
		"GN" => "Guinea",
		"GP" => "Guadeloupe",
		"GQ" => "Equatorial Guinea",
		"GR" => "Greece",
		"GS" => "South Georgia and the South Sandwich Islands",
		"GT" => "Guatemala",
		"GU" => "Guam",
		"GW" => "Guinea-Bissau",
		"GY" => "Guyana",
		"HK" => "Hong Kong",
		"HM" => "Heard Island and McDonald Islands",
		"HN" => "Honduras",
		"HR" => "Croatia",
		"HT" => "Haiti",
		"HU" => "Hungary",
		"ID" => "Indonesia",
		"IE" => "Ireland",
		"IL" => "Israel",
		"IM" => "Isle of Man",
		"IN" => "India",
		"IO" => "British Indian Ocean Territory",
		"IQ" => "Iraq",
		"IR" => "Islamic Republic of Iran",
		"IS" => "Iceland",
		"IT" => "Italy",
		"JE" => "Jersey",
		"JM" => "Jamaica",
		"JO" => "Jordan",
		"JP" => "Japan",
		"KE" => "Kenya",
		"KG" => "Kyrgyzstan",
		"KH" => "Cambodia",
		"KI" => "Kiribati",
		"KM" => "Comoros",
		"KN" => "Saint Kitts and Nevis",
		"KP" => "Democratic People's Republic of Korea",
		"KR" => "Republic of Korea",
		"KW" => "Kuwait",
		"KY" => "Cayman Islands",
		"KZ" => "Kazakhstan",
		"LA" => "Lao People's Democratic Republic",
		"LB" => "Lebanon",
		"LC" => "Saint Lucia",
		"LI" => "Liechtenstein",
		"LK" => "Sri Lanka",
		"LR" => "Liberia",
		"LS" => "Lesotho",
		"LT" => "Lithuania",
		"LU" => "Luxembourg",
		"LV" => "Latvia",
		"LY" => "Libyan Arab Jamahiriya",
		"MA" => "Morocco",
		"MC" => "Monaco",
		"MD" => "Moldova",
		"ME" => "Montenegro",
		"MF" => "Saint Martin",
		"MG" => "Madagascar",
		"MH" => "Marshall Islands",
		"MK" => "The Former Yugoslav Republic of Macedonia",
		"ML" => "Mali",
		"MM" => "Myanmar",
		"MN" => "Mongolia",
		"MO" => "Macao",
		"MP" => "Northern Mariana Islands",
		"MQ" => "Martinique",
		"MR" => "Mauritania",
		"MS" => "Montserrat",
		"MT" => "Malta",
		"MU" => "Mauritius",
		"MV" => "Maldives",
		"MW" => "Malawi",
		"MX" => "Mexico",
		"MY" => "Malaysia",
		"MZ" => "Mozambique",
		"NA" => "Namibia",
		"NC" => "New Caledonia",
		"NE" => "Niger",
		"NF" => "Norfolk Island",
		"NG" => "Nigeria",
		"NI" => "Nicaragua",
		"NL" => "Netherlands",
		"NO" => "Norway",
		"NP" => "Nepal",
		"NR" => "Nauru",
		"NU" => "Niue",
		"NZ" => "New Zealand",
		"OM" => "Oman",
		"PA" => "Panama",
		"PE" => "Peru",
		"PF" => "French Polynesia",
		"PG" => "Papua New Guinea",
		"PH" => "Philippines",
		"PK" => "Pakistan",
		"PL" => "Poland",
		"PM" => "Saint Pierre and Miquelon",
		"PN" => "Pitcairn",
		"PR" => "Puerto Rico",
		"PS" => "Occupied Palestinian Territory",
		"PT" => "Portugal",
		"PW" => "Palau",
		"PY" => "Paraguay",
		"QA" => "Qatar",
		"RE" => "Reunion",
		"RO" => "Romania",
		"RS" => "Serbia",
		"RU" => "Russian Federation",
		"RW" => "Rwanda",
		"SA" => "Saudi Arabia",
		"SB" => "Solomon Islands",
		"SC" => "Seychelles",
		"SD" => "Sudan",
		"SE" => "Sweden",
		"SG" => "Singapore",
		"SH" => "Saint Helena",
		"SI" => "Slovenia",
		"SJ" => "Svalbard and Jan Mayen",
		"SK" => "Slovakia",
		"SL" => "Sierra Leone",
		"SM" => "San Marino",
		"SN" => "Senegal",
		"SO" => "Somalia",
		"SR" => "Suriname",
		"ST" => "Sao Tome and Principe",
		"SU" => "Soviet Union",
		"SV" => "El Salvador",
		"SY" => "Syrian Arab Republic",
		"SZ" => "Swaziland",
		"TC" => "Turks and Caicos Islands",
		"TD" => "Chad",
		"TF" => "French Southern Territories",
		"TG" => "Togo",
		"TH" => "Thailand",
		"TJ" => "Tajikistan",
		"TK" => "Tokelau",
		"TL" => "Timor-Leste",
		"TM" => "Turkmenistan",
		"TN" => "Tunisia",
		"TO" => "Tonga",
		"TP" => "Portuguese Timor",
		"TR" => "Turkey",
		"TT" => "Trinidad and Tobago",
		"TV" => "Tuvalu",
		"TW" => "Taiwan",
		"TZ" => "United Republic of Tanzania",
		"UA" => "Ukraine",
		"UG" => "Uganda",
		"UK" => "United Kingdom",
		"UM" => "United States Minor Outlying Islands",
		"US" => "United States",
		"UY" => "Uruguay",
		"UZ" => "Uzbekistan",
		"VA" => "Holy See",
		"VC" => "Saint Vincent and the Grenadines",
		"VE" => "Venezuela",
		"VG" => "British Virgin Islands",
		"VI" => "U.S. Virgin Islands",
		"VN" => "Viet Nam",
		"VU" => "Vanuatu",
		"WF" => "Wallis and Futuna",
		"WS" => "Samoa",
		"YE" => "Yemen",
		"YT" => "Mayotte",
		"YU" => "Yugoslavia",
		"ZA" => "South Africa",
		"ZM" => "Zambia",
		"ZW" => "Zimbabwe",
	);
	if ( exists $TLD_map{$tld} ) {
		return "$TLD_map{$tld} ($tld)";
	} else {
		return $tld;
	}
} # End of get_countryname

sub ValidateIP($) {
	my $ip = shift;

	# check v4 IPs
	if (  $ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/ && 
	   (( $1 > 0 && $1 <=255 && $2 <= 255 && $3 <= 255 && $4 <= 255 ))) {
		return $ip;
	} 

	# check IPv6
	if ( $ip =~ /^$IPv6_re$/ ) {
		return $ip;
	}

	return undef;

} # End of ValidateIP

sub Reverse_name($) {
	my $ip = shift;

	my $af = $ip =~ /:/ ? PF_INET6 : PF_INET;

	my $hostname = scalar gethostbyaddr(inet_pton($af, $ip), $af);

	if ( !defined $hostname ) {
		$hostname = '&lt;not found&gt;';
	}

	return $hostname;
	
} # End of Reverse_name


sub do_whois($$) {
	my $item 		 = shift;
	my $whois_server = shift;

	LogDebug "Query $whois_server for $item";

	my $whois_socket = IO::Socket::INET->new(
		PeerAddr  => $whois_server,
		PeerPort  => 43,
		Proto	  => 'tcp',
		timeout	  => 10 );

	if ( !$whois_socket ) {
		LogError "Can't connect to whoisd: $@";
		return undef;
	}
	
	print $whois_socket "$item\n";

	my $result = [];
	while ( <$whois_socket> ) {
		chomp;
		next if $_ =~ /^$/;
		next if $_ =~ /^#/;
		push @{$result}, "$_";
#		LogDebug "$_";
	}
	close $whois_socket;

	return $result;

} # end of do_whois


sub ARNIN_stage1($) {
	my $ip = shift;

	my ($net, $org_id);
	$net    = undef;
	$org_id = undef;

	my $whois = do_whois($ip, 'whois.arin.net');

	if ( !defined $whois ) {
		return (undef, undef);
	}

	foreach ( @{$whois} ) {
		next if $_ =~ /^Various Registries/;
		next if $_ =~ /^American Registry/;
		if ( $_ =~ /\((NET-.+)\)/ ) {
			$net = $1;
			LogDebug "% Found net: $net";
		}
		if ( $_ =~ /NetHandle:\s+(NET-.+)/ ) {
			$net = $1;
			LogDebug "% Found net: $net";
		}
		if ( $_ =~ /NetHandle:\s+(NET6-.+)/ ) {
			$net = $1;
			LogDebug "% Found 6net: $net";
		}
		if ( $_ =~ /OrgId:\s+(.+)/ ) {
			$org_id = $1;
			LogDebug "% Found Org Id: $org_id";
		}
	}

	return ($net, $org_id);

} # End of ARNIN_stage1

sub ARNIN_stage2($) {
	my $ip = shift;

	my $org_id;
	my $whois = do_whois($ip, 'whois.arin.net');

	if ( !defined $whois ) {
		return undef;
	}

	foreach ( @{$whois} ) {
		next if $_ =~ /^Various Registries/;
		next if $_ =~ /^American Registry/;
		if ( $_ =~ /OrgId:\s+(.+)/ ) {
			$org_id = $1;
			LogDebug "% Found org_id: $org_id";
		}
		# LogDebug "$_";
	}

	return $org_id;

} # End of ARNIN_stage2

sub do_ARIN($$) {
	my $ip  = shift;
	my $net = shift;

	my $result = {};
	$result->{'Infos'} = ();
	$result->{'Source'} = 'ARIN';

	my $whois = do_whois($net, 'whois.arin.net');

	my $skip = 0;
	foreach ( @{$whois} ) {
		next if $skip;

		if ( $_ =~ /NetRange:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
		if ( $_ =~ /Net6Range:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
   		if ( $_ =~ /NetName:\s+(.+)/ ) {
			$result->{'Network name'} = $1;
		}
   		if ( $_ =~ /Country:\s+(.+)/ ) {
			$result->{'Country'} = $1 unless exists $result->{'Country'} ;
		}
   		if ( $_ =~ /OrgTechEmail:\s+(.+)/ ) {
			if ( exists $result->{'Abuse E-mail'} ) {
				$result->{'E-mail'} .= ", $1";
			} else {
				$result->{'E-mail'} = $1;
			}
		}
   		if ( $_ =~ /irt-nfy:\s+(.+)/ ) {
			$result->{'IRT notify'} = $1;
		}
		if ( $_ =~ /OrgName:\s+(.+)/ ) {
			push @{$result->{'Infos'}}, $1;
		}
		if ( $_ =~ /Address:\s+(.+)/ ) {
			push @{$result->{'Infos'}}, $1;
		}
		if ( $_ =~ /City:\s+(.+)/ ) {
			push @{$result->{'Infos'}}, $1;
		}
	}

	return $result;

} # End of do_ARIN

sub do_RIPE($) {
	my $ip = shift;

	my $org_id;
	my $result = {};
	$result->{'Infos'}  = ();
	$result->{'Source'} = 'RIPE';

	my $whois = do_whois($ip, 'whois.ripe.net');

	my $skip = 0;
	foreach ( @{$whois} ) {
		next if $skip;

		if ( $_ =~ /inetnum:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
		if ( $_ =~ /inet6num:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
   		if ( $_ =~ /netname:\s+(.+)/ ) {
			$result->{'Network name'} = $1;
		}
   		if ( $_ =~ /country:\s+(.+)/ ) {
			$result->{'Country'} = $1 unless exists $result->{'Country'} ;
		}
   		if ( $_ =~ /abuse-mailbox:\s+(.+)/ ) {
			if ( exists $result->{'Abuse E-mail'} ) {
				$result->{'Abuse E-mail'} .= ", $1";
			} else {
				$result->{'Abuse E-mail'} = $1;
			}
		}
   		if ( $_ =~ /e-mail:\s+(.+)/ ) {
			$result->{'E-mail'} = $1;
		}
   		if ( $_ =~ /irt-nfy:\s+(.+)/ ) {
			$result->{'IRT notify'} = $1;
		}
		if ( $_ =~ /descr:\s+(.+)/ ) {
			push @{$result->{'Infos'}}, $1;
		}
	}

	return $result;

} # End of do_RIPE

sub do_APNIC($) {
	my $ip = shift;

	my $org_id;
	my $result = {};
	$result->{'Infos'} = ();
	$result->{'Source'} = 'APNIC';

	my $whois = do_whois($ip, 'whois.apnic.net');

	my $skip = 0;
	foreach ( @{$whois} ) {
		next if $skip;

		if ( $_ =~ /inetnum:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
		if ( $_ =~ /inet6num:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
   		if ( $_ =~ /netname:\s+(.+)/ ) {
			$result->{'Network name'} = $1;
		}
   		if ( $_ =~ /country:\s+(.+)/ ) {
			$result->{'Country'} = $1 unless exists $result->{'Country'} ;
		}
   		if ( $_ =~ /abuse-mailbox:\s+(.+)/ ) {
			if ( exists $result->{'Abuse E-mail'} ) {
				$result->{'Abuse E-mail'} .= ", $1";
			} else {
				$result->{'Abuse E-mail'} = $1;
			}
		}
   		if ( $_ =~ /e-mail:\s+(.+)/ ) {
			$result->{'E-mail'} = $1;
		}
   		if ( $_ =~ /irt-nfy:\s+(.+)/ ) {
			$result->{'IRT notify'} = $1;
		}
		if ( $_ =~ /descr:\s+(.+)/ ) {
			push @{$result->{'Infos'}}, $1;
		}
	}

	return $result;

} # End of do_APNIC

sub do_LACNIC($) {
	my $ip = shift;

	my $org_id;
	my $result = {};
	$result->{'Infos'} = ();
	$result->{'Source'} = 'LACNIC';

	my $whois = do_whois($ip, 'whois.lacnic.net');

	my $skip = 0;
	foreach ( @{$whois} ) {
		next if $skip;

		if ( $_ =~ /inetnum:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
		if ( $_ =~ /inet6num:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
   		if ( $_ =~ /owner:\s+(.+)/ ) {
			$result->{'Network name'} = $1;
		}
   		if ( $_ =~ /country:\s+(.+)/ ) {
			$result->{'Country'} = $1 unless exists $result->{'Country'} ;
		}
   		if ( $_ =~ /abuse-mailbox:\s+(.+)/ ) {
			if ( exists $result->{'Abuse E-mail'} ) {
				$result->{'Abuse E-mail'} .= ", $1";
			} else {
				$result->{'Abuse E-mail'} = $1;
			}
		}
   		if ( $_ =~ /e-mail:\s+(.+)/ ) {
			$result->{'E-mail'} = $1;
		}
   		if ( $_ =~ /irt-nfy:\s+(.+)/ ) {
			$result->{'IRT notify'} = $1;
		}
		if ( $_ =~ /descr:\s+(.+)/ ) {
			push @{$result->{'Infos'}}, $1;
		}
	}

	return $result;

} # End of do_APNIC

sub do_AFRINIC($) {
	my $ip = shift;

	my $org_id;
	my $result = {};
	$result->{'Infos'} = ();
	$result->{'Source'} = 'AFRINIC';

	my $whois = do_whois($ip, 'whois.afrinic.net');

	my $skip = 0;
	foreach ( @{$whois} ) {
		next if $skip;

		if ( $_ =~ /inetnum:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
		if ( $_ =~ /inet6num:\s+(.+)/ ) {
			$result->{'IP range'} = $1;
		}
   		if ( $_ =~ /netname:\s+(.+)/ ) {
			$result->{'Network name'} = $1;
		}
   		if ( $_ =~ /country:\s+(.+)/ ) {
			$result->{'Country'} = $1 unless exists $result->{'Country'} ;
		}
   		if ( $_ =~ /abuse-mailbox:\s+(.+)/ ) {
			if ( exists $result->{'Abuse E-mail'} ) {
				$result->{'Abuse E-mail'} .= ", $1";
			} else {
				$result->{'Abuse E-mail'} = $1;
			}
		}
   		if ( $_ =~ /e-mail:\s+(.+)/ ) {
			$result->{'E-mail'} = $1;
		}
   		if ( $_ =~ /irt-nfy:\s+(.+)/ ) {
			$result->{'IRT notify'} = $1;
		}
		if ( $_ =~ /descr:\s+(.+)/ ) {
			push @{$result->{'Infos'}}, $1;
		}
	}

	return $result;

} # End of do_AFRINIC

# Entry point for Lookup
# sock   : to print result to.
# query  : query string
sub Query($$) {
	my $sock 	= shift;
	my $query	= shift;


	my $ip = ValidateIP($query);
	if ( !defined $ip ) {
		print $sock "Invalid IP address\n";
		return;
	}

	my $hostname = Reverse_name($ip);
	print $sock "<b>$ip -&gt; $hostname</b>\n";
	print $sock "<pre>\n";

	my ($net, $org_id) = ARNIN_stage1($ip);
	if ( !defined $net ) {
		print $sock "Failed to lookup IP address\n";
		return;
	}

	if ( !defined $org_id ) {
		$org_id = ARNIN_stage2($net);
	}

	# print $sock "% Net is: '$net', OrgID is '$org_id'\n";

	my $result;
	if ( exists $RegistryLookup{$org_id} ) {
		my $function = $RegistryLookup{$org_id};
		$result = &$function($ip, $net);
	} else {
		# default is ARIN
		$result = do_ARIN($ip, $net);
	}
	print $sock "IP range     : ", exists $result->{'IP range'} ? $result->{'IP range'} : "not found", "\n";
	print $sock "Network name : ", exists $result->{'Network name'} ? $result->{'Network name'} : "not found", "\n";
	if ( exists $result->{'Infos'} ) {
		my $infos = $result->{'Infos'};
		my %dup;
		foreach my $info ( @{$infos} ) {
			if ( exists $dup{$info} ) {
				next;
			}
			$dup{$info} = 1;
			print $sock "Infos        : $info\n";
		}
	}
	print $sock "Country      : ", exists $result->{'Country'} ? get_countryname($result->{'Country'}) : "unknown", "\n";
	print $sock "Abuse email  : $result->{'Abuse E-mail'}\n" if  exists $result->{'Abuse E-mail'};
	print $sock "E-mail       : $result->{'E-mail'}\n" if  exists $result->{'E-mail'};
	print $sock "Source       : ", exists $result->{'Source'} ? $result->{'Source'} : "unkbown", "\n";
	print $sock "<pre>\n";

} # End of Query

1;

#my $ip = shift;
#Query(*STDOUT, $ip);
