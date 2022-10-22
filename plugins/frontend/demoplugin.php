<?php

/*
 * Frontend plugin: demoplugin
 *
 * Required functions: demoplugin_ParseInput and demoplugin_Run
 *
 */

/* 
 * demoplugin_ParseInput is called prior to any output to the web browser 
 * and is intended for the plugin to parse possible form data. This 
 * function is called only, if this plugin is selected in the plugins tab. 
 * If required, this function may set any number of messages as a result 
 * of the argument parsing.
 * The return value is ignored.
 */
function demoplugin_ParseInput( $plugin_id ) {

	SetMessage('error', "Error set by demo plugin!");
	SetMessage('warning', "Warning set by demo plugin!");
	SetMessage('alert', "Alert set by demo plugin!");
	SetMessage('info', "Info set by demo plugin!");

} // End of demoplugin_ParseInput


/*
 * This function is called after the header and the navigation bar have 
 * are sent to the browser. It's now up to this function what to display.
 * This function is called only, if this plugin is selected in the plugins tab
 * Its return value is ignored.
 */
function demoplugin_Run( $plugin_id ) {

	print "<h3>Hello I'm the demo plugin with id $plugin_id</h3>\n";
	print "Query backend plugin for function <b>try</b><br>\n";

	// the command to be executed in the backend plugin
	$command = 'demoplugin::try';

	// two scalar values
	$colour1 = '#72e3fa';
	$colour2 = '#2a6f99';

	// one array
	$colours = array ( '#12af7d', '#56fc7b');

	// prepare arguments
	$opts = array();
	$opts['colour1'] = $colour1;
	$opts['colour2'] = $colour2;
	$opts['colours'] = $colours;

	// call command in backened plugin
    $out_list = nfsend_query($command, $opts);

	// get result
    if ( !is_array($out_list) ) {
        SetMessage('error', "Error calling backend plugin");
        return FALSE;
    }
	$string = $out_list['string'];
	print "Backend reported: <b>$string</b><br>\n";

	print "<h3>Picture sent from the backend</h3>\n";
	print "<IMG src='pic.php?picture=smily.jpg' border='0' alt='Smily'>\n";

} // End of demoplugin_Run


?>
