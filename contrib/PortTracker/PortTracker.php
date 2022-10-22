<?php

$proto = array ( 'tcp', 'udp' );
$type  = array ( 'flows', 'packets', 'bytes' );

$PortDisplayOrder = array ( 
	'TCP Flows', 'TCP Packets', 'TCP Bytes' ,
	'UDP Flows', 'UDP Packets', 'UDP Bytes' 
);

$PortTracker_WinSizeLabels = array ( '12 Hours', '1 day', '2 days', '4 days', '1 week', '2 weeks' );
$PortTracker_WinSizeFactor = array ( 0.5       ,  1     ,  2      ,  4      ,  7      , 14);


function GetTopN($plugin_id, $avg24) {

	$opts = array();
	$opts['interval'] = $avg24 ? 24 : 1;
	$out_list = nfsend_query('PortTracker::get-topN', $opts, 0);
	if ( !is_array($out_list) ) {
		SetMessage('error', "Can not read topN list");
		return FALSE;
	}


	$TopNline = $out_list['topN'];

	/*
	 * 1116607500
	 * 10 0 0
	 * 80 135 445 389 3306 1433 4899 4662 8443 25 
	 * 84046 52201 40543 28801 28419 16487 11108 7741 7278 6671 
	 * 10 1 0
	 * 80 4662 22 119 20012 18253 9541 5001 2170 1521 
	 * 2338000 382084 276332 227355 161488 152253 148814 147927 144201 134825 
	 * 10 2 0
	 * 119 4662 80 20012 5001 18253 9541 21961 22 20031 
	 * 319375447 254166206 238879858 238653710 220220412 219223561 207939341 195786183 166321579 160794781 
	 * 10 0 1
	 * 53 1434 1026 4672 137 123 32768 6881 32769 6346 
	 * 89132 58020 52625 24686 15922 15880 3872 3498 3495 3181 
	 * 10 1 1
	 * 53 1026 6346 1434 7000 2326 6970 4672 40977 61402 
	 * 200335 81466 77864 58021 45615 45130 39208 32767 30482 30448 
	 * 10 2 1
	 * 1026 6970 1434 0 6346 6010 53 7001 2328 2485 
	 * 38730783 26212262 23450415 21575743 20986592 18556143 16716194 14235457 10624559 9905871 
	 */

	$TopNInfo = array();
	$index = 1;
	$TopNInfo[] = array_shift($TopNline);
	for ( $i=0; $i < 6; $i++ ) {
		$_tmp = array_shift($TopNline);
		list( $num, $typeindex, $protoindex) = explode(' ', $_tmp);
	
		// Top N port numbers
		$_tmp = array_shift($TopNline);
		$TopNInfo[$protoindex+1][$typeindex][0] = explode(' ', $_tmp);

		// Top N values
		$_tmp = array_shift($TopNline);
		$TopNInfo[$protoindex+1][$typeindex][1] = explode(' ', $_tmp);
	}

	return $TopNInfo;

} // End of GetTopN

function DisplayTopNPorts ($plugin_id, $topNinfo ) {

	global $self;
	global $proto;
	global $type;
	global $PortDisplayOrder;
	global $PortTracker_WinSizeLabels;
	global $PortTracker_WinSizeFactor;

	$tend = $topNinfo[0];

	// calculate tstart according the window size. The 'PortTracker_WinSizeFactor' array contains the
	// factor how many days ( 86400s ) back this window scale 'wsize'  relates
	$tstart = $tend - $PortTracker_WinSizeFactor[$_SESSION["${plugin_id}_wsize"]] * 86400;

	$logscale  		= $_SESSION["${plugin_id}_logscale"];
	$stacked  		= $_SESSION["${plugin_id}_stacked"];
	$maingraph 		= $_SESSION["${plugin_id}_graph"];
	$mainprotoindex = $maingraph < 3 ? 0 : 1;
	$maintypeindex  = $maingraph < 3 ? $maingraph : $maingraph - 3;

	$track_list = count($_SESSION["${plugin_id}_track"]) > 0 ? implode('-', $_SESSION["${plugin_id}_track"]) : '-';
	
	$skip_list  = count($_SESSION["${plugin_id}_skip"]) > 0 ? implode('-', $_SESSION["${plugin_id}_skip"]) : '-';

	if ( count($_SESSION["${plugin_id}_track"]) == 0 && $_SESSION["${plugin_id}_topN"] == 0 )
		$_SESSION["${plugin_id}_topN"] = 1;
	
	if ( ( count($_SESSION["${plugin_id}_skip"]) > 0 ) && ( count($_SESSION["${plugin_id}_skip"]) >= $_SESSION["${plugin_id}_topN"] ))
		$_SESSION["${plugin_id}_topN"] = count($_SESSION["${plugin_id}_skip"]) + 1;


	// if we don't have any top N to display, disable the radio buttons for 24 hour stat
	if ( $_SESSION["${plugin_id}_topN"] == 0 ) {
		$radio_state = 'disabled';
		$_SESSION["${plugin_id}_24avg"] == 0;
	} else {
		$radio_state = '';
	} 

// print "<pre>";
// print_r($topNinfo);
// print "</pre>";

?>

<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <meta content="text/html; charset=ISO-8859-1"
 http-equiv="content-type">
  <title>test</title>
</head>
<body>


<table style="text-align: left;" border="0" cellpadding="3"
 cellspacing="2">
  <tbody>
    <tr>
      <td>
      <table style="text-align: left;" border="0" cellpadding="0" cellspacing="3">
        <tbody>
          <tr>
<?php
		  	for ( $i=1; $i < count($PortDisplayOrder); $i++ ) {
				$label = $PortDisplayOrder[$i];
				if ( $i == $maingraph ) {
					$label = $PortDisplayOrder[0];
				} 
        		print "<td>";
        		print $label;
        		print "</td>\n";
			}
       		print "</tr>\n";
       		print "<tr>\n";

		  	for ( $i=1; $i < count($PortDisplayOrder); $i++ ) {
				$protoindex = $i < 3 ? 0 : 1;
				$typeindex  = $i < 3 ? $i : $i - 3;
				$g_id = $i;
				if ( $i == $maingraph ) {
					$protoindex = 0;
					$typeindex  = 0;
					$g_id = 0;
				}

				// Arguments for GenPortGraph
				// proto typw  logscale light tstart     tend       topN              staticN
				// tcp   flows 0        0     1116495000 1116581400 '22 445 135 1433' '80 143'

        		print "<td>";
				if ( $_SESSION["${plugin_id}_topN"] ) 
					$topNlist = implode('-', array_slice( $topNinfo[$protoindex + 1][$typeindex][0], 0, $_SESSION["${plugin_id}_topN"]) );
				else 
					$topNlist = '-';
				$arg = $proto[$protoindex] . ' ' . $type[$typeindex] . " $logscale $stacked 1 $tstart $tend $topNlist $track_list $skip_list";
        		$arg = urlencode($arg);

        		$label = $proto[$protoindex] . '-' . $type[$typeindex];
				print "<a href='$self?${plugin_id}_graph=$g_id'> " .  
          			  "<img src=rrdgraph.php?cmd=PortTracker::get-portgraph&profile=./live&arg=$arg border='0' width='165' height='81' alt='$label'></a>\n";

        		// print $proto[$protoindex] . ' ' . $type[$typeindex];
				// print "<br>$arg\n";
        		print "</td>\n";
			}
?>
          </tr>
        </tbody>
      </table>
      </td>
    </tr>
    <tr>
		<td style="vertical-align: bottom;"> 
			<table>
				<tr>
					<td>
<?php
					if ( $_SESSION["${plugin_id}_topN"] ) 
						$topNlist = implode('-', array_slice( $topNinfo[$mainprotoindex + 1][$maintypeindex][0], 0, $_SESSION["${plugin_id}_topN"]));
					else
						$topNlist = '-';

					$arg = $proto[$mainprotoindex] . ' ' . $type[$maintypeindex] . " $logscale $stacked 0 $tstart $tend $topNlist $track_list $skip_list";
        			$arg = urlencode($arg);
        			$label = $proto[$mainprotoindex] . '-' . $type[$maintypeindex];
					print "<img src=rrdgraph.php?cmd=PortTracker::get-portgraph&profile=./live&arg=$arg border='0' width='669' height='396' alt='$label'>\n";

        			// print $proto[$mainprotoindex] . ' ' . $type[$maintypeindex];
					// print "<br>$arg\n";
?>
					</td>
					<td style="vertical-align: top;"> 
					<table>

					<tr>
						<td>
							<form action="<?php echo $self;?>" method="POST">
							Show Top&nbsp;
<?php
							print "<select name='${plugin_id}_topN' onchange='this.form.submit();' size=1>\n";
							$_tmp = count($topNinfo[1][0][0]);
							for ( $i = 0; $i <= $_tmp; $i++ ) {
								if ( $i == $_SESSION["${plugin_id}_topN"] )
									print "<option value='$i' selected>" . $i . "\n";
								else
									print "<option value='$i'>$i\n";
							}
							print "</select>\n";
?>
							Ports
							</form>
						</td>
					</tr>

					<tr><td>
						<form action="<?php echo $self;?>" method="POST">
						<input type="radio" onClick='this.form.submit();' name='<?php echo "${plugin_id}_24avg";?>' value="0"
						<?php if ( $_SESSION["${plugin_id}_24avg"] == 0 ) print "checked"; ?> <?php print $radio_state;?> >now&nbsp;
						<input type="radio" onClick='this.form.submit();' name='<?php echo "${plugin_id}_24avg";?>' value="1"
						<?php if ( $_SESSION["${plugin_id}_24avg"] == 1 ) print "checked"; ?> <?php print $radio_state;?> >24 hours
						</td>
						</form>
					</tr>

					<tr>
					<td style='padding-top:20px;'>
						Track Ports:<br>
						<form action="<?php echo $self;?>" method="POST">
						<select name='<?php echo "${plugin_id}_track";?>' style='width:100%;padding-bottom:20px;' size=2>
<?php
						for ( $i = 0; $i < count($_SESSION["${plugin_id}_track"]); $i++ ) {
							$_tmp = $_SESSION["${plugin_id}_track"][$i];
							print "<option value='$_tmp'>" . $_tmp . "\n";
						}
?>
						</select>

					<p>
						<input type='text' name='<?php echo "${plugin_id}_trackport";?>' value='' size='5' maxlength='5' >
						<input type='submit' name='<?php echo "${plugin_id}_action";?>' value='Add' >
						<input type='submit' name='<?php echo "${plugin_id}_action";?>' value='Delete' >
						</form>
					</td>
					</tr>

					<tr>
					<td style='padding-top:20px;'>
						Skip Ports:<br>
						<form action="<?php echo $self;?>" method="POST">
						<select name='<?php echo "${plugin_id}_skip";?>' style='width:100%;padding-bottom:20px;' size=2>
<?php
						for ( $i = 0; $i < count($_SESSION["${plugin_id}_skip"]); $i++ ) {
							$_tmp = $_SESSION["${plugin_id}_skip"][$i];
							print "<option value='$_tmp'>" . $_tmp . "\n";
						}
?>
						</select>

					<p>
						<input type='text' name='<?php echo "${plugin_id}_skipport";?>' value='' size='5' maxlength='5' >
						<input type='submit' name='<?php echo "${plugin_id}_action";?>' value='Add' >
						<input type='submit' name='<?php echo "${plugin_id}_action";?>' value='Delete' >
						</form>
					</td>
					</tr>

					</table>
					</td>
				</tr>

				<tr>
					<td>
					<table style='width:100%;'>
					<tr>
						<td style='padding-top:0px;'>
						<form action="<?php echo $self;?>" method="POST" style="display:inline">Display
						<select name='<?php echo "${plugin_id}_wsize";?>' onchange='this.form.submit();' size=1>
<?php
						for ( $i = 0; $i < count($PortTracker_WinSizeLabels); $i++ ) {
							if ( $i == $_SESSION["${plugin_id}_wsize"] )
								print "<option value='$i' selected>" . $PortTracker_WinSizeLabels[$i] . "</option>\n";
							else
								print "<option value='$i'>" . $PortTracker_WinSizeLabels[$i] . "</option>\n";
						}
?>
						</select>
						</td>
						<td>
						Y-axis:
						<input type="radio" onClick='this.form.submit();' name='<?php echo "${plugin_id}_logscale";?>' value="0"
						<?php if ( $_SESSION["${plugin_id}_logscale"] == 0 ) print "checked"; ?> >Linear
						<input type="radio" onClick='this.form.submit();' name='<?php echo "${plugin_id}_logscale";?>' value="1"
						<?php if ( $_SESSION["${plugin_id}_logscale"] == 1 ) print "checked"; ?> >Log
						</td>
						<td>
						Type:
						<input type="radio" onClick='this.form.submit();' name='<?php echo "${plugin_id}_stacked";?>' value="1"
						<?php if ( $_SESSION["${plugin_id}_stacked"] == 1 ) print "checked"; ?> >Stacked
					
						<input type="radio" onClick='this.form.submit();' name='<?php echo "${plugin_id}_stacked";?>' value="0"
						<?php if ( $_SESSION["${plugin_id}_stacked"] == 0 ) print "checked"; ?> >Line
				
						</form>
					</tr>
					</table>
					</td><td><td></td>
				</tr>

			</table>
		</td>
    </tr>
  </tbody>
</table>


</body>
</html>

<?php
} // End of DisplayTopNPorts

function DumpTopNPorts($plugin_id, $topNinfo) {

	$topN = $_SESSION["${plugin_id}_topN"];

	if ( $topN == 0 )
		return;
?>

	<p style='padding-top:10px;'>
	Top <?php echo $topN;?> Statistics
	<br>
	<table>
		<tr>
			<td></td>
			<td colspan=6 bgcolor='#EEEEEE' style="text-align: center;">TCP</td>
			<td colspan=6 bgcolor='#EEEEEE' style="text-align: center;">UDP</td>
		</tr>
		<tr>
			<td></td>
			<td colspan=2 bgcolor='#EEEEEE' style='text-align: center;'>Flows</td>
			<td colspan=2 bgcolor='#EEEEEE' style='text-align: center;'>Packets</td>
			<td colspan=2 bgcolor='#EEEEEE' style='text-align: center;'>Bytes</td>
			<td colspan=2 bgcolor='#EEEEEE' style='text-align: center;'>Flows</td>
			<td colspan=2 bgcolor='#EEEEEE' style='text-align: center;'>Packets</td>
			<td colspan=2 bgcolor='#EEEEEE' style='text-align: center;'>Bytes</td>
		</tr>
		<tr>
			<td bgcolor='#EEEEEE'>Rank</td>
			<td bgcolor='#EEEEEE'>Port</td>
			<td bgcolor='#EEEEEE'>Count</td>
			<td bgcolor='#EEEEEE'>Port</td>
			<td bgcolor='#EEEEEE'>Count</td>
			<td bgcolor='#EEEEEE'>Port</td>
			<td bgcolor='#EEEEEE'>Count</td>
			<td bgcolor='#EEEEEE'>Port</td>
			<td bgcolor='#EEEEEE'>Count</td>
			<td bgcolor='#EEEEEE'>Port</td>
			<td bgcolor='#EEEEEE'>Count</td>
			<td bgcolor='#EEEEEE'>Port</td>
			<td bgcolor='#EEEEEE'>Count</td>
		</tr>
<?php
	for ( $i = 0; $i < $topN ; $i++ ) {
		$rank = $i + 1;
		print "<tr>\n";
		print "<td bgcolor='#EEEEEE'>$rank</td>\n";
		for ( $proto=1; $proto<3; $proto++ ) {
			for ($type=0; $type<3; $type++) {
				print "<td bgcolor='#A8A8A8' align='right'>" . $topNinfo[$proto][$type][0][$i] . "</td>\n";
				print "<td bgcolor='#CCCCCC' align='right'>" . $topNinfo[$proto][$type][1][$i] . "</td>\n";
			}
		}
		print "</tr>\n";
	}
?>
	</table>


<?php

} // End of DumpTopNPorts

function PortTracker_ParseInput ($plugin_id) {

	global $PortDisplayOrder;

	// Which graph to display
	if ( isset($_GET["${plugin_id}_graph"]) ) {
		$_tmp = $_GET["${plugin_id}_graph"];
		if ( !is_numeric($_tmp) || ($_tmp > count($PortDisplayOrder)) || ($_tmp < 0)) {
			$_SESSION['warning'] = "Can't display graph '$_tmp'";
		} else {
			$_SESSION["${plugin_id}_graph"] = $_tmp;
		}
	} 
	if ( !isset($_SESSION["${plugin_id}_graph"]) ) {
			$_SESSION["${plugin_id}_graph"] = 0;
	}
	if ( !isset($_SESSION["${plugin_id}_skip"]) ) {
			$_SESSION["${plugin_id}_skip"] = array();
	}
	if ( !isset($_SESSION["${plugin_id}_track"]) ) {
			$_SESSION["${plugin_id}_track"] = array();
	}

	$_SESSION['rrdgraph_getparams']['profile'] = 1;
	// register 'get-portgraph' command for rrdgraph.php
	if ( !array_key_exists('rrdgraph_cmds', $_SESSION) || 
		 !array_key_exists('PortTracker::get-portgraph', $_SESSION['rrdgraph_cmds']) ) {
		$_SESSION['rrdgraph_cmds']['PortTracker::get-portgraph'] = 1;
	} 
	$_SESSION['rrdgraph_getparams']['profile'] = 1;

	// Top N ports
	if ( isset($_POST["${plugin_id}_topN"]) ) {
		$_tmp = $_POST["${plugin_id}_topN"];
		if ( !is_numeric($_tmp) || ($_tmp > 10) || ($_tmp < 0)) {
			$_SESSION['warning'] = "Invalid Top N number. Defaults to 10.";
			$_SESSION["${plugin_id}_topN"] = 10;
		} else {
			$_SESSION["${plugin_id}_topN"] = $_tmp;
		}
	}
	if ( !isset($_SESSION["${plugin_id}_topN"]) ) {
			$_SESSION["${plugin_id}_topN"] = 10;
	}

	// Static tracked ports
	if ( isset($_POST["${plugin_id}_action"]) ) {
		switch ($_POST["${plugin_id}_action"]) {
		case 'Add':
			$_track_tmp = isset($_POST["${plugin_id}_trackport"]) ? $_POST["${plugin_id}_trackport"] : 0;
			$_skip_tmp = isset($_POST["${plugin_id}_skipport"]) ? $_POST["${plugin_id}_skipport"] : 0;
			if ( $_track_tmp > 0 && $_track_tmp < 65536 ) {
				if ( in_array($_track_tmp, $_SESSION["${plugin_id}_track"]) ) {
					SetMessage('error', "Port $_track_tmp already in skip list");
				} else if ( !in_array($_track_tmp, $_SESSION["${plugin_id}_track"]) ) {
					$_SESSION["${plugin_id}_track"][] = $_track_tmp;
				}
			} else if ( $_skip_tmp > 0 && $_skip_tmp < 65536 ) {
				if ( in_array($_skip_tmp, $_SESSION["${plugin_id}_skip"]) ) {
					$_SESSION['error'] = "Port $_skip_tmp already in track list";
				} else if ( !in_array($_skip_tmp, $_SESSION["${plugin_id}_skip"]) ) {
					$_SESSION["${plugin_id}_skip"][] = $_skip_tmp;
				}
			} else {
				SetMessage('error', "Invalid Port");
			}

			break;
		case 'Delete':
			$_track_tmp = isset($_POST["${plugin_id}_track"]) ? $_POST["${plugin_id}_track"] : 0;
			if ( $_track_tmp > 0 && $_track_tmp < 65536 ) {
				if ( in_array($_track_tmp, $_SESSION["${plugin_id}_track"]) ) {

					// remove $_track_tmp from array. As we don't know, where it is, cycle through the array
					$count = count($_SESSION["${plugin_id}_track"]);
					for ( $i=0; $i<$count; $i++) {
						$_port = array_shift($_SESSION["${plugin_id}_track"]);
						if ( $_port != $_track_tmp ) {
							array_push($_SESSION["${plugin_id}_track"], $_port);
						}
					}
				}
			}

			$_skip_tmp = isset($_POST["${plugin_id}_skip"]) ? $_POST["${plugin_id}_skip"] : 0;
			if ( $_skip_tmp > 0 && $_skip_tmp < 65536 ) {
				if ( in_array($_skip_tmp, $_SESSION["${plugin_id}_skip"]) ) {

					// remove $_skip_tmp from array. As we don't know, where it is, cycle through the array
					$count = count($_SESSION["${plugin_id}_skip"]);
					for ( $i=0; $i<$count; $i++) {
						$_port = array_shift($_SESSION["${plugin_id}_skip"]);
						if ( $_port != $_skip_tmp ) {
							array_push($_SESSION["${plugin_id}_skip"], $_port);
						}
					}
				}
			}
			break;

		}
	}

	if ( !isset($_SESSION["${plugin_id}_track"]) ) {
			$_SESSION["${plugin_id}_track"] = array();
	}

	// Graph wsize
	if ( isset($_POST["${plugin_id}_wsize"]) ) {
		$_tmp = $_POST["${plugin_id}_wsize"];
		if ( !is_numeric($_tmp) || ($_tmp > 5) || ($_tmp < 0)) {
			$_SESSION['warning'] = "Invalid Window scale. Defaults to 1 day.";
			$_SESSION["${plugin_id}_wsize"] = 1;
		} else {
			$_SESSION["${plugin_id}_wsize"] = $_tmp;
		}
	}
	if ( !isset($_SESSION["${plugin_id}_wsize"]) ) {
			$_SESSION["${plugin_id}_wsize"] = 1;
	}

	// Graph Scale
	if ( isset($_POST["${plugin_id}_logscale"]) ) {
		$_tmp = $_POST["${plugin_id}_logscale"];
		if ( !is_numeric($_tmp) || ($_tmp > 1) || ($_tmp < 0)) {
			$_SESSION['warning'] = "Invalid Graph Scaling. Defaults to linear.";
			$_SESSION["${plugin_id}_logscale"] = 0;
		} else {
			$_SESSION["${plugin_id}_logscale"] = $_tmp;
		}
	}
	if ( !isset($_SESSION["${plugin_id}_logscale"]) ) {
			$_SESSION["${plugin_id}_logscale"] = 0;
	}

	// Stacked Graph 
	if ( isset($_POST["${plugin_id}_stacked"]) ) {
		$_tmp = $_POST["${plugin_id}_stacked"];
		if ( !is_numeric($_tmp) || ($_tmp > 1) || ($_tmp < 0)) {
			$_SESSION['warning'] = "Invalid Graph Scaling. Defaults to linear.";
			$_SESSION["${plugin_id}_stacked"] = 0;
		} else {
			$_SESSION["${plugin_id}_stacked"] = $_tmp;
		}
	}
	if ( !isset($_SESSION["${plugin_id}_stacked"]) ) {
			$_SESSION["${plugin_id}_stacked"] = 0;
	}

	// 24 hour average
	if ( isset($_POST["${plugin_id}_24avg"]) ) {
		$_tmp = $_POST["${plugin_id}_24avg"];
		if ( !is_numeric($_tmp) || ($_tmp > 1) || ($_tmp < 0)) {
			$_SESSION['warning'] = "Invalid Graph Scaling. Defaults to linear.";
			$_SESSION["${plugin_id}_24avg"] = 0;
		} else {
			$_SESSION["${plugin_id}_24avg"] = $_tmp;
		}
	}
	if ( !isset($_SESSION["${plugin_id}_24avg"]) ) {
			$_SESSION["${plugin_id}_24avg"] = 0;
	}


} // End of PortTracker_ParseInput

function PortTracker_Run($plugin_id) {

	global $PortDisplayOrder;

	print "<h3>Port Tracker</h3>\n";

	$portinfo = GetTopN($plugin_id, $_SESSION["${plugin_id}_24avg"]);
	if ( $portinfo == FALSE ) {
		print "<h3>Error reading stat</h3>\n";
		return;
	}
	$graph = 0;

	DisplayTopNPorts($plugin_id, $portinfo );
// print "<pre>";
// print_r($_POST);
// print_r($_SESSION);
// print "</pre>";
	DumpTopNPorts($plugin_id, $portinfo);

} // End of PortTracker_Run

?>
