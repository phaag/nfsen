<?php

include ("conf.php");
include ("nfsenutil.php");
session_start();
unset($_SESSION['nfsend']);

function OpenLogFile () {
	global $log_handle;
	global $DEBUG;

	if ( $DEBUG ) {
		$log_handle = fopen("/var/tmp/nfsen-log", "a");
		$_d = date("Y-m-d-H:i:s");
		ReportLog("\n=========================\nDetails Graph run at $_d\n");
	} else 
		$log_handle = null;

} // End of OpenLogFile

function CloseLogFile () {
	global $log_handle;

	if ( $log_handle )
		fclose($log_handle);

} // End of CloseLogFile

function ReportLog($message) {
	global $log_handle;

	if ( $log_handle )
		fwrite($log_handle, "$message\n");
} // End of ReportLog

OpenLogFile();

$lookup = urldecode($_GET['lookup']);
$opts = array();
$opts['lookup'] = $lookup;

header("Content-type: text/html; charset=ISO-8859-1");
?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
<title>Lookup: '<?php echo $lookup;?>'</title>
<meta HTTP-EQUIV="Pragma" CONTENT="no-cache">
<link rel="stylesheet" type="text/css" href="css/lookup.css">
</head>
<body>

<?php

nfsend_query("@lookup", $opts, 1);
nfsend_disconnect();
unset($_SESSION['nfsend']);
CloseLogFile();

?>

</body>
</html>
