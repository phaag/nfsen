<?php

function navigator () {

	global $self;
	global $TabList;
	global $GraphTabs;

	$numtabs = count($TabList);

	$plugins  = GetPlugins ();
	$profiles = GetProfiles();
	$profileswitch = $_SESSION['profileswitch'];

	switch ( $_SESSION['profileinfo']['type'] & 3 ) {
		case 0:
			$profile_type = 'live';
			break;
		case 1:
			$profile_type = 'history';
			break;
		case 2:
			$profile_type = 'continuous';
			break;
		default:
			$type = 'unknown';
	}
	$profile_type .= ($_SESSION['profileinfo']['type'] & 4) > 0  ? '&nbsp;/&nbsp;shadow' : '';


?>
	<form action="<?php echo $self?>" name='navi' method="POST">
	<div class="shadetabs"><br>
	<table border='0' cellpadding="0" cellspacing="0">
	<tr>
		<td>
			<ul>
<?php
			for ( $i = 0; $i <  $numtabs; $i++ ) {
				if ( $i == $_SESSION['tab'] ) {
					print "<li class='selected'><a href='$self?tab=$i'>" . $TabList[$i] . "</a></li>\n";
				} else {
					print "<li><a href='$self?tab=$i'>" . $TabList[$i] . "</a></li>\n";
				}
			}
?>
			</ul>
		</td>
		<td class="navigator">
<?php echo $profile_type;?>
		</td>
		<td class="navigator">
<?php 		print "<a href='$self?bookmark=" . $_SESSION['bookmark'] . "'>Bookmark URL</a>\n"; ?>
		</td>
		<td class="navigator">Profile:</td>
		<td>
			<a class="select_pullup" id="profilemenu" href="javascript:void(0);" 
				onclick="openSelect(this);" onMouseover="selectMouseOver();" 
				onMouseout="selectMouseOut();"></a>
		</td>
	</tr>
	</table>
	<input type="hidden" id="profilemenu_field" name="profileswitch" value="<?php echo $profileswitch;?>"> 
 	</div>

<?php 
	$_tab = $_SESSION['tab'];
	if ( $TabList[$_tab] == 'Graphs' ) {
		$_sub_tab = $_SESSION['sub_tab'];
?>
		<div class="shadetabs"><br>
		<table border='0' cellpadding="0" cellspacing="0">
		<tr>
			<td>
				<ul>
<?php
					for ( $i = 0; $i <  count($GraphTabs); $i++ ) {
						if ( $i == $_sub_tab ) {
							print "<li class='selected'><a href='$self?sub_tab=$i'>" . $GraphTabs[$i] . "</a></li>\n";
						} else {
							print "<li><a href='$self?sub_tab=$i'>" . $GraphTabs[$i] . "</a></li>\n";
						}
					}
?>
				</ul>
			</td>
		</tr>
		</table>
		</div>
<?php

	}
	if ( $TabList[$_tab] == 'Plugins' ) {
		if ( count($plugins) == 0 ) {
?>
			<div class="shadetabs"><br>
				<h3 style='margin-left: 10px;margin-bottom: 2px;margin-top: 2px;'>No plugins available!</h3>
			</div>
<?php
		} else {
?>
		<div class="shadetabs"><br>
		<table border='0' cellpadding="0" cellspacing="0">
		<tr>
			<td>
				<ul>
<?php
					for ( $i = 0; $i <  count($plugins); $i++ ) {
						if ( $i == $_SESSION['sub_tab'] ) {
							print "<li class='selected'><a href='$self?sub_tab=$i'>" . $plugins[$i] . "</a></li>\n";
						} else {
							print "<li><a href='$self?sub_tab=$i'>" . $plugins[$i] . "</a></li>\n";
						}
					}
?>
				</ul>
			</td>
		</tr>
		</table>
		</div>
<?php
		}
	}
	print "</form>\n";
	print "<script language='Javascript' type='text/javascript'>\n";
	print "selectMenus['profilemenu'] = 0;\n";

	$i = 0;
	$savegroup = '';
	$groupid = 0;
    foreach ( $profiles as $profileswitch ) {
		if ( preg_match("/^(.+)\/(.+)/", $profileswitch, $matches) ) {
			$profilegroup = $matches[1];
			$profilename  = $matches[2];
			if ( $profilegroup == '.' ) {
				print "selectOptions[selectOptions.length] = '0||$profilename||./$profilename'; \n";
			} else {
				if ( $profilegroup != $savegroup ) {
					$savegroup = $profilegroup;
					print "selectOptions[selectOptions.length] = '0||$profilegroup||@@0.$i'; \n";
					$groupid = $i;
					$i++;
				}
				print "selectOptions[selectOptions.length] = '0.$groupid||$profilename||$profilegroup/$profilename'; \n";
			}
		} else {
			print "selectOptions[selectOptions.length] = '0||$profileswitch||$profileswitch'; \n";
		}
		$i++;
    }

	print "selectRelateMenu('profilemenu', function() { document.navi.submit(); });\n";
	// print "selectRelateMenu('profilemenu', false );\n";

	print "</script>\n";
	print "<noscript><h3 class='errstring'>Your browser does not support JavaScript! NfSen will not work properly!</h3></noscript>\n";
	$bk = base64_decode(urldecode($_SESSION['bookmark']));

} // End of navigator

