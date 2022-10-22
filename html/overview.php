<?php

function DisplayOverview () {

	global $self;

	$profile      = $_SESSION['profile'];
	$profilegroup = $_SESSION['profilegroup'];

	if ( $profilegroup == '.' ) 
		print "<h2>Overview Profile: $profile, Group: (nogroup)</h2>\n";
	else 
		print "<h2>Overview Profile: $profile, Group $profilegroup</h2>\n";

	if ( $_SESSION['profileinfo']['graphs'] != 'ok' ) {
		print "<h2>No data available!</h2>\n";
		return;
	}

	$profileswitch = "$profilegroup/$profile";
	print "<a href='$self?tab=2&type=flows'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=flows-day' width='328' height='163' border='0' alt='flows-day'></a>\n";
	print "<a href='$self?tab=2&type=packets'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=packets-day' width='328' height='163' border='0' alt='packets-day'></a>\n";
	print "<a href='$self?tab=2&type=traffic'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=traffic-day' width='328' height='163' border='0' alt='traffic-day'></a>\n";
	print "<br>";
	print "<a href='$self?tab=2&type=flows'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=flows-week' width='328' height='163' border='0' alt='flows-week'></a>\n";
	print "<a href='$self?tab=2&type=packets'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=packets-week' width='328' height='163' border='0' alt='packets-week'></a>\n";
	print "<a href='$self?tab=2&type=traffic'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=traffic-week' width='328' height='163' border='0' alt='traffic-week'></a>\n";
	print "<br>";
	print "<a href='$self?tab=2&type=flows'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=flows-month' width='328' height='163' border='0' alt='flows-month'></a>\n";
	print "<a href='$self?tab=2&type=packets'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=packets-month' width='328' height='163' border='0' alt='packets-month'></a>\n";
	print "<a href='$self?tab=2&type=traffic'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=traffic-month' width='328' height='163' border='0' alt='traffic-month'></a>\n";	
	print "<br>";
	print "<a href='$self?tab=2&type=flows'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=flows-year' width='328' height='163' border='0' alt='flows-year'></a>\n";
	print "<a href='$self?tab=2&type=packets'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=packets-year' width='328' height='163' border='0' alt='packets-year'></a>\n";
	print "<a href='$self?tab=2&type=traffic'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=traffic-year' width='328' height='163' border='0' alt='traffic-year'></a>\n";	

} // End of DisplayOverview

function DisplayGraphs ($type) {

	global $self;

	$profile      = $_SESSION['profile'];
	$profilegroup = $_SESSION['profilegroup'];

	if ( $profilegroup == '.' ) 
		print "<h2>Profile: $profile, Group: (nogroup) - $type</h2>\n";
	else
		print "<h2>Profile: $profile, Group: $profilegroup - $type</h2>\n";

	if ( $_SESSION['profileinfo']['graphs'] != 'ok' ) {
		print "<h2>No data available!</h2>\n";
		return;
	}

	$profileswitch = "$profilegroup/$profile";
	print "<a href='$self?tab=2&win=day&type=$type'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=${type}-day' width='669' height='281' border='0'></a>\n";
	print "<br>";
	print "<a href='$self?tab=2&win=week&type=$type'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=${type}-week' width='669' height='281' border='0'></a>\n";
	print "<br>";
	print "<a href='$self?tab=2&win=month&type=$type'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=${type}-month' width='669' height='281' border='0'></a>\n";
	print "<br>";
	print "<a href='$self?tab=2&win=year&type=$type'> <IMG src='pic.php?profileswitch=$profileswitch&amp;file=${type}-year' width='669' height='281' border='0'></a>\n";
	print "<br>";

} # End of DisplayHistory

?>
