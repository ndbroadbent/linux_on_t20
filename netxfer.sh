#! /bin/sh
# Title:
#    netxfer.sh
#
# Author:
#    Karl Mowatt-Wilson
#    http://mowson.org/karl
#    copyright: 2007 Karl Mowatt-Wilson
#    licence: GPL v2
#
# Revisions:
#    v0.1  - 21 Jun 2007 - first release 
#    v0.11 - 23 Jun 2007 - add 'readability' check of full image path 
#    v0.12 - 23 Jun 2007 - improve readability check
#    v0.13 -  6 Jul 2007 - add 'tail' of syslog
#                        - put port numbers in variables
#                        - use getopts
#                        - incorporate PXE serving modes
#                        - improve tidying on exit
#    v0.14 - 28 Sep 2007 - patch kindly provided by Malte Stretz
#                           - cope with dhcpd3 dropping privileges
#                           - exit gracefully on ctrl+c
#    v0.15 - 16 Jan 2008 - Changed method of getting IP address of interface
#                           - old method was susceptible to translation problems

Usage () {
cat <<-EOF
	
	USAGE: 
	   netxfer.sh [mode] [-i interface] [directory] [file]
	
	This script sets up dhcpd/tftpd to temporarily serve files for either
	flashing an Evo T20 with new firmware, or booting a PXE client.  The
	netxfer mode is meant to replicate the function of the netxfer tool 
	used under windows.  The servers are killed on script exit.
	
	If neither directory nor file are specified, both are set to defaults as per
	the mode (see MODE below).
	If only a directory is specified, the file is set to default.
	If only a file is specified, the file is set to the filename and the directory
	is set to the directory of the file.
	If both directory and file are specified, the file is assumed to be specified 
	relative to the directory.
	
	Note that all files to be served must be readable by 'other'.  Directories to
	be served from must also be executable by 'other'.  Otherwise the tftp client
	will complain of not being able to find the file or access denied.
	Note also that long image filenames may not work (maybe a tftp problem, maybe 
	a T20 problem).
	
	In theory, netxfer mode is safe to run on a network that already has
	a dhcp server, since we are using non-standard ports which will not 
	interfere with any existing normal server.  The same is true with the 
	alternate PXE mode.  
	
	MODE:
	   -a  Setup as PXE server with alternate dhcp ports (1067,1068), so as not 
	       to clash with any existing dhcp server on the same network.  Default 
	       directory to serve is '/tftpboot' and default file is 'pxelinux.0'
	       You need a non-standard PXE client for this (it is one of the options
	       with etherboot/rom-o-matic though).
	          
	   -n  This is the default mode.  Setup as Netxfer server for flashing 
	       firmware of Evo T20.  Uses ports 10067 & 10068 for dhcp, and 
	       port 10069 for tftp.  Default directory to serve is './' and default 
	       file is 'bootp.bin'
	  
	   -p  Setup as PXE server.  Used ports 67 & 68 for dhcp, and port 69 for
	       tftp.  Default directory to serve is '/tftpboot' and default file
	       is 'pxelinux.0'
	
	OPTIONS:
	   -i interface
	       Specify an alternate interface to listen on.  Default is eth0.
	
	EXAMPLES:
	   netxfer.sh
	      - plain netxfer of ./bootp.bin, using ports 10067-10069 on eth0.
	
	   netxfer.sh -a -i eth1 /pxedir extradir/file
	      - PXE serve /pxedir/extradir/file, using ports 69, 1067-1068 on eth1.
	
EOF
}
###########################################################################

# Define interface to listen on - probably 'eth0'
INTERFACE="eth0"

# Define range of IPs to hand out to clients: x.x.x.START - x.x.x.STOP
# First 3 octets come from IP of INTERFACE, which we figure out automatically.
IP_LAST_OCTET_START=230
IP_LAST_OCTET_STOP=240


# Define set of options for files to serve
NETXFER_TFTP_BASE="."
NETXFER_TFTP_FILE="bootp.bin"

PXE_TFTP_BASE="/tftpboot"
PXE_TFTP_FILE="pxelinux.0"

ALT_PXE_TFTP_BASE="/tftpboot"
ALT_PXE_TFTP_FILE="pxelinux.0"


# Define ports to use
NETXFER_DHCP_PORT=10067
NETXFER_TFTP_PORT=10069

PXE_DHCP_PORT=67
PXE_TFTP_PORT=69

ALT_PXE_DHCP_PORT=1067
ALT_PXE_TFTP_PORT=69


# set the defaults (can be overridden by commandline options)
DHCP_PORT="$NETXFER_DHCP_PORT"
TFTP_PORT="$NETXFER_TFTP_PORT"
TFTP_BASE="$NETXFER_TFTP_BASE"
TFTP_FILE="$NETXFER_TFTP_FILE"


SYSLOG="/var/log/syslog"

###########################################################################
## Function to exit with error message.
## First param is return code, remaining params are lines of error message.
#
Fail() {
   ExitCode=$1
   shift
   echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
   echo "$(basename "$0"): FATAL ERROR" >&2
   while [ $# -gt 0 ]; do
      echo "$1" >&2
      shift
   done
   sleep 2
   TidyUp
   exit $ExitCode
}

###########################################################################
## Function to tidy up temp files/dirs before exit.
#
TidyUp() {
   echo "=== Tidying ========================================================="
   [ "$TFTPD_PID" ] \
      && ps --pid $TFTPD_PID >/dev/null 2>/dev/null \
         && kill $TFTPD_PID 

   [ "$DHCPD_PID_TMP" ] && [ -s "$DHCPD_PID_TMP" ] \
      && kill $(cat "$DHCPD_PID_TMP") >/dev/null 2>/dev/null 

   [ -d "$DHCPD_TMP" ] && rm -r "$DHCPD_TMP"
}

###########################################################################
## Function to check a list of desired tools are available.
#
Toolcheck() {
   while [ $# -gt 0 ]; do
      TOOL="$1"
      shift
      echo "Checking '$TOOL'"
      which "$TOOL" >/dev/null 2>/dev/null \
         || Fail 3 "'which' failed for '$TOOL' - can't find this command."
   done
}   


###########################################################################
#==========================================================================
# Parse command-line options.

while getopts "ai:np" OPT; do
   case $OPT in
      a)   # Alternate PXE setup
           DHCP_PORT="$ALT_PXE_DHCP_PORT"
           TFTP_PORT="$ALT_PXE_TFTP_PORT"
           TFTP_BASE="$ALT_PXE_TFTP_BASE"
           TFTP_FILE="$ALT_PXE_TFTP_FILE"
           ;;
      i)   # choose Interface to listen on
           INTERFACE=$OPTARG 
           ;;
      n)   # Netxfer setup
           DHCP_PORT="$NETXFER_DHCP_PORT"
           TFTP_PORT="$NETXFER_TFTP_PORT"
           TFTP_BASE="$NETXFER_TFTP_BASE"
           TFTP_FILE="$NETXFER_TFTP_FILE"
           ;;
      p)   # PXE setup
           DHCP_PORT="$PXE_DHCP_PORT"
           TFTP_PORT="$PXE_TFTP_PORT"
           TFTP_BASE="$PXE_TFTP_BASE"
           TFTP_FILE="$PXE_TFTP_FILE"
           ;;
      *)   Usage 
           exit 
           ;;
    esac
done
shift $(($OPTIND - 1)); OPTIND=1

# Accept dir and file specified on commandline
[ "$1" ] && TFTP_BASE="$1"
[ "$2" ] && TFTP_FILE="$2"

# Canonicalise the path
TFTP_BASE="$(readlink -f "$TFTP_BASE")"

# Deal with only a file specified
[ -f "$TFTP_BASE" ] && {
   # Split filespec into dir & file
   TFTP_FILE="$(basename "$TFTP_BASE")"
   TFTP_BASE="$(dirname  "$TFTP_BASE")"
   [ "$2" ] && {
      # If a file is specified first then there should be no second param
      echo "WARNING: '$1' is a file, so am ignoring '$2'"
      sleep 2
   }   
}   

#==========================================================================
# Check that we have a hope of any of this working.
WARN_PAUSE=""

[ "$(id -u)" -eq 0 ] || {
   echo "WARNING: You don't seem to be root - this probably won't work..."
   WARN_PAUSE="TRUE"
}

ps -C in.tftpd >/dev/null && {
   echo "WARNING: There is already a tftpd running..."
   WARN_PAUSE="TRUE"
}

ps -C dhcpd >/dev/null && {
   echo "WARNING: There is already a dhcpd running..."
   WARN_PAUSE="TRUE"
}

[ "$WARN_PAUSE" ] && {
   echo "This may or may not be a problem!"
   sleep 2
   echo "Continuing anyway."
}   

#==========================================================================
echo "=== Checking tools =================================================="
Toolcheck   \
   dhcpd3   \
   in.tftpd \
   ifconfig \
   grep     \
   head

#==========================================================================
# Get the IP address for the desired interface (usually eth0).
# Old version which fails with i18n of 'addr': 
#  IP=$(ifconfig "$INTERFACE" | grep -oE 'addr:[0-9.]+' | grep -oE '[0-9.]+')
IP=$(ifconfig "$INTERFACE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
[ "$IP" ] || Fail 3 "Could not get IP address for '$INTERFACE'"

IP_3_OCTETS=$(echo $IP | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')

# define range of IPs to hand out to clients
IP_START="$IP_3_OCTETS.$IP_LAST_OCTET_START"
IP_STOP="$IP_3_OCTETS.$IP_LAST_OCTET_STOP"

IP_SUBNET="$IP_3_OCTETS.0"
IP_NETMASK="255.255.255.0"

#==========================================================================
# Check that IMAGE is good & readable.

TFTP_FULLPATH="$TFTP_BASE/$TFTP_FILE"

echo "Checking access to '$TFTP_FULLPATH'"
[ -d "$TFTP_BASE" ]     || Fail 3 "'$TFTP_BASE' appears not to be a directory!"
[ -e "$TFTP_FULLPATH" ] || Fail 3 "'$TFTP_FULLPATH' doesn't exist!"
[ -f "$TFTP_FULLPATH" ] || Fail 3 "'$TFTP_FULLPATH' appears not to be a file!"

# Traverse the path and check that *every* element is readable by 'other'.
# (this might be overkill)
BADPATH=""
CHKPATH="$TFTP_FULLPATH"
while [ "$CHKPATH" ]; do
   PERMS="$(stat "$CHKPATH" --format="%A")"
   [ "$(echo "$PERMS" | cut -c8)" = 'r' ] || {
      echo "WARNING: 'other' can't read   '$CHKPATH'"
      BADPATH="true"
   }
   [ -d "$CHKPATH" ] && {
      [ "$(echo "$PERMS" | cut -c10)" = 'x' ] || {
         echo "WARNING: 'other' can't access '$CHKPATH'"
         BADPATH="true"
      }
   }
   if [ "$CHKPATH" = "/" ]; then
      CHKPATH=""
   else
      CHKPATH="$(dirname "$CHKPATH")"
   fi
done

[ "$BADPATH" ] && {
   echo "Unreadability might prevent tftpd from being able to serve files."
   echo "You probably need to do 'chmod o+r' on files or 'chmod o+rx' on directories."
   sleep 2
}   
   

#==========================================================================
# If we have lsof available, check that nothing is already bound to our ports
#which lsof >/dev/null 2>/dev/null && {
#   ERR="$(lsof -i $INTERFACE:$DHCP_PORT)"
#   [ "$ERR" ] && \
#      Fail 3 "Something is already bound to our intended dhcp port" "$ERR"
#}

#==========================================================================
echo \
"==========================================================================
OK - everything looks workable so far: 
   Interface:   $INTERFACE
   Our IP:      $IP
   Serving IPs: $IP_START .. $IP_STOP
   DHCP port:   $DHCP_PORT
   TFTP port:   $TFTP_PORT
   TFTP root:   '$TFTP_BASE'
   TFTP file:   '$TFTP_FILE'
=========================================================================="  

#==========================================================================
# Make temp files for storing dhcpd info; it will drop privileges

DHCPD_CHROOT_CF=/conf
DHCPD_CHROOT_RW=/rw
DHCPD_CHROOT_PF=$DHCPD_CHROOT_RW/pid
DHCPD_CHROOT_LF=$DHCPD_CHROOT_RW/leases

# create a ro temp directory
DHCPD_TMP="$(mktemp -t $(basename $0)-dhcpd.XXXXXXXXXX)" \
  || Fail 3 "Couldn't mktemp for dhcpd temp files"
rm "$DHCPD_TMP" \
  || Fail 3 "Couldn't rm for dhcpd temp files"
mkdir -m 711 "$DHCPD_TMP" \
  || Fail 3 "Couldn't mkdir for dhcpd temp files"

# create a rw sub temp directory
mkdir -m 777 "$DHCPD_TMP/$DHCPD_CHROOT_RW" \
  || Fail 3 "Couldn't mkdir rw temp dir"

# create empty pid and lease file in rw space
DHCPD_PID_TMP="$DHCPD_TMP$DHCPD_CHROOT_PF"
DHCPD_LF_TMP="$DHCPD_TMP$DHCPD_CHROOT_LF"
touch $DHCPD_PID_TMP $DHCPD_LF_TMP 
chmod 666 $DHCPD_PID_TMP $DHCPD_LF_TMP

# create ro conf file
DHCPD_CONF_TMP="$DHCPD_TMP$DHCPD_CHROOT_CF"
touch $DHCPD_CONF_TMP
chmod 644 $DHCPD_CONF_TMP
cat >"$DHCPD_CONF_TMP" <<-EOF
	# We might as well be authoritative. 
	authoritative;
	
	# We don't need ddns updating
	ddns-update-style none;

	# Let addresses be recycled quickly - 10minutes 
	default-lease-time 600;
	max-lease-time 600;
	
	subnet $IP_SUBNET netmask $IP_NETMASK {
	   # Range of dynamic IP addresses to hand out.
	   range dynamic-bootp $IP_START $IP_STOP;
	   # IP address for client to request tftp from.
	   next-server $IP;
	   # File for client to request via tftp.
	   filename "$TFTP_FILE";
	}
EOF

#==========================================================================
# Start log display, setup to quit when this script exits.
if [ -r "$SYSLOG" ]; then
   echo "Starting syslog display..."
   (tail "$SYSLOG" -f -n 0 -q --pid=$$ \
      | grep -E '(dhcpd|tftpd)' \
   ) &
else
   echo "WARNING: No access to $SYSLOG - not going to display log info."
   SYSLOG=""
fi 


echo ==========================================================================
echo "Starting tftpd..."

# in.tftpd options:
#    -a = specify address/port
#    -l = standalone (listen) mode, not inetd mode
#    -s = change root dir on startup
#    -v = verbose logging (may be specified multiple times)
#    -B = max block size - too big can be a problem if it causes fragmentation
#    -R = server port range
#    -T = timeout in microseconds, before first pkt is retransmitted
in.tftpd -l -v -a $IP:$TFTP_PORT -s "$TFTP_BASE" -B 65464 -R 30000:39999 -T 6000000 \
   || Fail 3 "tftpd failed"

# Try to get the pid of the most recently started tftpd.
# Not very precise, but better than using killall!
# If you have lsof installed, you could use something like
# this to get the pid:  lsof -Fp -ni @$IP:$PORT | grep -Eo '[0-9]+'
# Or maybe use pidof / netstat?
TFTPD_PID=$(ps kstart_time -o pid -C in.tftpd --no-headers | tail)

[ "$SYSLOG" ] \
   || echo "SYSLOG not defined, so TFTP progress will not be displayed here."

echo ==========================================================================
echo "Starting dhcpd..."

# dhcpd3 options:
#    -d  = log to stderr - only do this if syslog tail failed above.
#    -p  = port to listen on
#    -q  = quiet - don't print licence info on startup
#    -cf = config file
#    -lf = lease file
#    -pf = pid file
if [ "$SYSLOG" ]; then
   LOGOPTIONS="-q"
else
   LOGOPTIONS="-d"
fi
dhcpd3 $LOGOPTIONS -p $DHCP_PORT -cf "$DHCPD_CONF_TMP" -lf "$DHCPD_LF_TMP" -pf "$DHCPD_PID_TMP" "$INTERFACE" &

#==========================================================================
# Shutdown daemons and remove the temp files on exit
trap TidyUp EXIT
trap exit INT
#==========================================================================

#==========================================================================
# Check that daemons haven't failed on us.
sleep 1
ps --pid $TFTPD_PID --no-headers >/dev/null 2>/dev/null || {
   Fail 3 "tftpd seems not to be running!"
}   
ps --pid $(cat $DHCPD_PID_TMP) --no-headers >/dev/null 2>/dev/null || {
   Fail 3 "dhcpd seems not to be running!"
}
#==========================================================================
# Wait around until quitting time.
echo ==========================================================================
echo 'Press <ENTER> to quit.'
while ! read DUMMY; do sleep 0.5; done

