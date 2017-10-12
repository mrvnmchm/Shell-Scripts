

#!/bin/sh
#
#  Script %name:        AutoLogin.sh %
#  Instance:            1 %
#  %version:            5 %
#  Description:
#  %created_by:         jdetchev %
#  %date_created:       Thu Jun 18 11:04:25 2015 %
#  %revised_by:		mrvnmchm %
#  %revision_date:		Wed Feb  1 11:31:11 2017 %

################################################################################
# Constants
################################################################################

readonly SCRIPT_VERSION=5 # TODO Update this value upon each check in!
readonly ALPHABET="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
export AUTO_LOGIN_PASSWORD_FILE=$PASS_FILE

function log {
  echo "`date \"+%Y/%m/%d %H:%M:%S %Z\"`: $1"
}

function usage {

    cat <<!
Usage: `basename $1` -u <Username> -c <Session Name> -b <Instance Base URL> -h <GUI Manager Host> -p <GUI Manager Port> [-m <max time> ] [-s <session_id_file>]

    Version: $SCRIPT_VERSION

        -u  Username
            The test username to log in with.
        -c  Session Cookie Name
            The name of the Session Cookie.
        -b  NPAC Instance Base URL
            The Base URL for the instance, URL and region.
        -h  GUI Manager Host
            The GUI Manager Host
        -p  GUI Manager Port
            The GUI Manager Port
        -m  Max Time (seconds, Optional)
            If present, will pass as max-time argument to curl calls.
            If not present, will allow the call to wait indefinitely
        -s  Session ID File (Optional)
            If argument present, will attempt to read session id from file and use in request.
            If argument present, will write used session id out to file if successful.
            If argument not present, will generate new session and not write to file

    Note: Before script is invoked, you must set the "AUTO_LOGIN_PASSWORD_FILE" environment variable to the full path of a file which contains
          the encrypted password to be used. This file should only be readable by the same user the script runs as.
          Content of the file must be already encrypted according to GUI/Client protocol.

    Exit Status Codes:

        0 - Login/Logout completed successfully
        1 - Login/Logout failure (Check logged output for more information)
        2 - Usage error (Missing or invalid argument, etc)

!
    exit 2
}

function rotate_cmd {
  # A faithful ksh recreation of "Translate" method from ServerTransaction.java
  cmd=$1
  sid=$2
  tmp_rot_cmd=""

  sid=`echo ${sid#-}`

  rem=`expr $sid - $sid / 26 \* 26`

  if [ $rem -eq 0 ]; then
    rem=1
  fi

  for charIndex in {1..4}; do
    char=`expr substr $cmd $charIndex 1`
    asciiChar=`printf '%d\n' "'$char"`
    asciiChar=`expr $asciiChar + $rem - 65`
    if [ $asciiChar -gt 25 ]; then
      asciiChar=`expr $asciiChar - 26`
    fi
    asciiChar=`expr $asciiChar + 1` # Since alphabet is 0-indexed
    rot_char=`expr substr $ALPHABET $asciiChar 1`
    tmp_rot_cmd="${tmp_rot_cmd}${rot_char}"
  done

  rot=`expr $rem - $rem / 4 \* 4`

  if [ $rot -ne 0 ]; then
     rot=`expr $rot + 1` # Since expr substr is 1-indexed
    rot_cmd=`expr substr $tmp_rot_cmd $rot 1`
    for charIndex in {2..4}; do
      if [ $charIndex -eq $rot ]; then
        rot_cmd="${rot_cmd}`expr substr $tmp_rot_cmd 1 1`"
      else
        rot_cmd="${rot_cmd}`expr substr $tmp_rot_cmd $charIndex 1`"
      fi
    done
  else
    rot_cmd=$tmp_rot_cmd
  fi

  echo $rot_cmd
}

function createSess {

if [ -n "$session_id_file" -a -r "$session_id_file" ]; then
  session_id=`cat $session_id_file`
fi

curl_createSession="curl -s -S --dump-header \-"

if [ -n "$session_id" ]; then
  curl_createSession="${curl_createSession} --cookie ${session_cookie_name}=${session_id}"
fi

if [ -n "$max_time" ]; then
  curl_createSession="${curl_createSession} --max-time $max_time"
fi

curl_createSession="${curl_createSession} https://${base_url}/gui_base/fcgi-bin/PageServer/Logon 2>&1"
log "Create Session Command: '$curl_createSession'"
createSessionResult=`eval $curl_createSession`
createSessionExitStatus=$?

# But use whatever session is supplied by the server
session_id=`echo "$createSessionResult" | grep "Set-Cookie:" | sed "s/.*${session_cookie_name}=\(.*\)|.*|.*/\1/"`

if [ $createSessionExitStatus -ne 0 -o -z "$session_id" ]; then
  log "Could not obtain session_id."
  log "CURL exit status = '$createSessionExitStatus'."
  log "CURL create session result = '$createSessionResult'."
  exit 1
fi

log "Logging in with session_id: '$session_id'"
}

loginNewUser(){

## Build the Pipe-Delimited String
guiString="${session_id}|${username}|1|${password}|"
guiStringLength=${#guiString}
guiStringLength=`printf "%07d" $guiStringLength` #Length must be padded to seven characters

## Rotate the login command, based on the session id
loginCode=`rotate_cmd "LOGN" "$session_id"`

## Add the login code and the gui string length to the message
guiString="${loginCode}${guiStringLength}${guiString}"

LOGIN_SCENARIO_FILE="login.scn.$$"

echo "$gui_manager_host" > $LOGIN_SCENARIO_FILE
echo "$gui_manager_port" >> $LOGIN_SCENARIO_FILE
echo -n "$guiString" >> $LOGIN_SCENARIO_FILE

## Do the Login
curl_loginSession="curl -s -S --data-binary @${LOGIN_SCENARIO_FILE} -H \"Content-Type: application/octet-stream\""

if [ -n "$max_time" ]; then
  curl_loginSession="${curl_loginSession} --max-time $max_time"
fi

curl_loginSession="${curl_loginSession} https://${base_url}/gui_base/cgi-bin/CgiAdapter 2>&1"

log "Login Session Command: '$curl_loginSession'"
log "Login Pipe-Delimted String: '$guiString'"
loginResult=`eval "$curl_loginSession"`
loginExitStatus=$?

rm $LOGIN_SCENARIO_FILE

log "Login Result: '$loginResult'"

if [ $loginExitStatus -ne 0 ]; then
  log "Login failed due to CURL error."
  log "CURL exit status = '$loginExitStatus'."
  logoffUser
  exit 1
fi

## Verify Login Status Code
loginResponseCode=`expr substr "$loginResult" 1 4`

if [ "$loginResponseCode" != "LOGR" ]; then
  log "Login failed due to error. Response to Login was '$loginResponseCode'."
  log "CURL exit status = '$loginExitStatus'."
  logoffUser
  exit 1
fi

# Status code is after the string size, but before the first pipe (|) char
endOfSizeIndex=12

firstPipeIndex=`expr index "$loginResult" "|"`

lengthOfStatusCode=`expr $firstPipeIndex - $endOfSizeIndex`

loginStatusCode=`expr substr "$loginResult" $endOfSizeIndex $lengthOfStatusCode`

if [ $loginStatusCode == 2 ]; then
  ## log update
  log "Login failed due to \"Duplicate Session\" error."
  log "CURL exit status = '$loginExitStatus'."
  ##Logoff User
  ## Build the Pipe-Delimted String
  guiString="${session_id}|prev|"
  guiStringLength=${#guiString}
  guiStringLength=`printf "%07d" $guiStringLength` #Length must be padded to seven characters

  ## Rotate the log off command, based on the session id
  dup_logoffCode=`rotate_cmd "DLGN" "$session_id"`

  guiString="${dup_logoffCode}${guiStringLength}${guiString}"

  ## Build the scenario file (filename includes PID for parallel invocation)
  ## Same note about newlines applies above
  DUP_LOGOFF_SCENARIO_FILE="dup_logoff.scn.$$"

  echo "$gui_manager_host" > $DUP_LOGOFF_SCENARIO_FILE
  echo "$gui_manager_port" >> $DUP_LOGOFF_SCENARIO_FILE
  echo -n "$guiString" >> $DUP_LOGOFF_SCENARIO_FILE

  ## Do the Logoff
  curl_duplogoffSession="curl -s -S --data-binary @${DUP_LOGOFF_SCENARIO_FILE} -H \"Content-Type: application/octet-stream\""

  if [ -n "$max_time" ]; then
    curl_duplogoffSession="${curl_duplogoffSession} --max-time $max_time"
  fi

  curl_duplogoffSession="${curl_duplogoffSession} https://${base_url}/gui_base/cgi-bin/CgiAdapter 2>&1"

  log "Logoff Command: '$curl_duplogoffSession'"
  log "Logoff Pipe-Delimted String: '$guiString'"
  dup_logoffResult=`eval "$curl_duplogoffSession"`
  dup_logoffExitStatus=$?

  rm ${DUP_LOGOFF_SCENARIO_FILE}

  ## Verify Logoff CURL request

  log "Logoff Result: '$dup_logoffResult'"
  ##Login User
  loginNewUser
  logoffUser
  exit 1
fi

if [ $loginStatusCode -ne 1 ]; then
  log "Login failed due to error. Login status code was '$loginStatusCode'."
  log "CURL exit status = '$loginExitStatus'."
  logoffUser
  exit 1
fi
}

function logoffUser {

  ## Build the Pipe-Delimted String
  guiString="${session_id}|"
  guiStringLength=${#guiString}
  guiStringLength=`printf "%07d" $guiStringLength` #Length must be padded to seven characters

  ## Rotate the log off command, based on the session id
  logoffCode=`rotate_cmd "LOGF" "$session_id"`

  guiString="${logoffCode}${guiStringLength}${guiString}"

  ## Build the scenario file (filename includes PID for parallel invocation)
  ## Same note about newlines applies above
  LOGOFF_SCENARIO_FILE="logoff.scn.$$"

  echo "$gui_manager_host" > $LOGOFF_SCENARIO_FILE
  echo "$gui_manager_port" >> $LOGOFF_SCENARIO_FILE
  echo -n "$guiString" >> $LOGOFF_SCENARIO_FILE

  ## Do the Logoff
  curl_logoffSession="curl -s -S --data-binary @${LOGOFF_SCENARIO_FILE} -H \"Content-Type: application/octet-stream\""

  if [ -n "$max_time" ]; then
    curl_logoffSession="${curl_logoffSession} --max-time $max_time"
  fi

  curl_logoffSession="${curl_logoffSession} https://${base_url}/gui_base/cgi-bin/CgiAdapter 2>&1"

  log "Logoff Command: '$curl_logoffSession'"
  log "Logoff Pipe-Delimted String: '$guiString'"
  logoffResult=`eval "$curl_logoffSession"`
  logoffExitStatus=$?

  rm ${LOGOFF_SCENARIO_FILE}

  ## Verify Logoff CURL request

  log "NPAC Logoff Result: '$logoffResult'"

  if [ $logoffExitStatus -ne 0 ]; then
    log "Logoff failed due to CURL error."
    log "CURL exit status = '$logoffExitStatus'."
    exit 1
  fi

  ## Verify Logoff
  logoffResponseCode=`expr substr "$logoffResult" 1 4`
  logoffResponseMsgCode=`expr substr "$logoffResult" 12 4`

  if [ "$logoffResponseCode" != "REQS" -o "$logoffResponseMsgCode" != "LOGF" ]; then
    log "Logoff failed due to error. Logoff Response Code: '$logoffResponseCode'. Logoff Response Msg Code: '$logoffResponseMsgCode'."
    log "CURL exit status = '$logoffExitStatus'."
    exit 1
  fi

  ## Check logoff success
  logoffStatusCode=`expr substr "$logoffResult" 17 1`

  if [ $logoffStatusCode -ne 1 ]; then
    log "Logoff failed due to error. Logoff status code was '$logoffStatusCode'."
    log "CURL exit status = '$logoffExitStatus'."
    exit 1
  fi

}

# Parse Command Line parameters

username=""
session_cookie_name=""
base_url=""
gui_manager_host=""
gui_manager_port=""
max_time=""
session_id_file=""

# Parse command line options.
while getopts u:c:b:h:p:m:s: OPT; do
    case "$OPT" in
        u)  username=$OPTARG;;
        c)  session_cookie_name=$OPTARG;;
        b)  base_url=$OPTARG;;
        h)  gui_manager_host=$OPTARG;;
        p)  gui_manager_port=$OPTARG;;
        m)  max_time=$OPTARG;;
        s)  session_id_file=$OPTARG;;
        \?) usage $0;;
    esac
done

if [ -n "$AUTO_LOGIN_PASSWORD_FILE" -a -r "$AUTO_LOGIN_PASSWORD_FILE" ]; then
  password=`cat $AUTO_LOGIN_PASSWORD_FILE`
else
  echo -e "\nAUTO_LOGIN_PASSWORD_FILE must be defined and point to a readable file.\n"
  usage $0
fi

# Check for required parameters
if [ -z "$username" -o -z "$password" -o -z "$session_cookie_name" -o -z "$base_url" -o -z "$gui_manager_host" -o -z "$gui_manager_port" ]; then
  echo -e "\nThe following arguments are required: username, session cookie name, base url, gui manager host, gui manager port.\n"
  echo -e "A password must also be present in the file path indicate by AUTO_LOGIN_PASSWORD_FILE\n"
  usage $0
fi

log "Attempting login with username='$username' and password='$password'."

##CREATE SESSION
createSess

##LOGIN USER
loginNewUser

##LOGOFF USER
logoffUser

## Write out session id, if file specified

if [ -n "$session_id_file" ]; then
  if [ -f "$session_id_file" -a ! -w "$session_id_file" ]; then
    log "Could not write out session id to '$session_id_file', file not writable."
  else
    echo $session_id > $session_id_file
         fi
fi

