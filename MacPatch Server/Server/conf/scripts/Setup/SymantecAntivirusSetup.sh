#!/bin/bash

#-----------------------------------------
# MacPatch SAV Defs Sync Setup Script
# MacPatch Version 2.1.x
#
# Script Ver. 1.0.0
#
#-----------------------------------------
clear

# Variables
MP_SRV_BASE="/Library/MacPatch/Server"
MP_SRV_CONF="${MP_SRV_BASE}/conf"
MP_DEFAULT_PORT="3601"

function checkHostConfig () {
	if [ "`whoami`" != "root" ] ; then   # If not root user,
	   # Run this script again as root
	   echo
	   echo "You must be an admin user to run this script."
	   echo "Please re-run the script using sudo."
	   echo
	   exit 1;
	fi
}

function configAVSync () 
{	
	server_name=`hostname -f`
	read -p "MacPatch Server Name: [$server_name]: " server_name
	server_name=${server_name:-`hostname -f`}
	defaults write ${MP_SRV_BASE}/conf/etc/gov.llnl.mp.AVDefsSync 'MPServerAddress' "$server_name"
	
	read -p "Use SSL for MacPatch connection [Y]: " -e t1
	if [ -n "$t1" ]; then
		if [ "$t1" == "y" ] || [ "$t1" == "Y" ]; then
			server_port="2600"
		else	
			read -p "MacPatch Port [$MP_DEFAULT_PORT]: " server_port
			server_port=${server_port:-$MP_DEFAULT_PORT}
		fi
	
		defaults write ${MP_SRV_BASE}/conf/etc/gov.llnl.mp.AVDefsSync 'MPServerPort' "$server_port"
	fi
	
	if [ -f /Library/MacPatch/Server/conf/LaunchDaemons/gov.llnl.mp.AVDefsSync.plist ]; then
		if [ -f /Library/LaunchDaemons/gov.llnl.mp.AVDefsSync.plist ]; then
			rm /Library/LaunchDaemons/gov.llnl.mp.AVDefsSync.plist
		fi
		ln -s /Library/MacPatch/Server/conf/LaunchDaemons/gov.llnl.mp.AVDefsSync.plist /Library/LaunchDaemons/gov.llnl.mp.AVDefsSync.plist
	fi
	chown root:wheel /Library/MacPatch/Server/conf/LaunchDaemons/gov.llnl.mp.AVDefsSync.plist
	chmod 644 /Library/MacPatch/Server/conf/LaunchDaemons/gov.llnl.mp.AVDefsSync.plist

}

# -----------------------------------
# Main
# -----------------------------------

checkHostConfig

# -----------------------------------
# Config AV
# -----------------------------------

read -p "Would you like to run the Symantec Antivirus virus defs on this host [Y]: " avServer_default
avServer_default=${avServer_default:-Y}
if [ "$avServer_default" == "y" ] || [ "$avServer_default" == "Y" ]; then
	echo "Configuring Symantec Antivirus Sync..."
	configAVSync
fi