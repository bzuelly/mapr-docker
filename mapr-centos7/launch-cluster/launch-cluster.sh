#!/bin/bash
commandLine="$0 $@"
[[ -z $DEBUG ]] && DEBUG=false
$DEBUG && set -x

# MapR Core and MEP versions are set in ../version.sh
[[ -f ../version.sh ]] && . ../version.sh

[[ -z MAPR_CORE_VER ]] && MAPR_CORE_VER="5.2.0"
[[ -z MAPR_MEP_VER ]] && MAPR_MEP_VER="1.1.0"
D_MAPR_SERVER_IMG=mapr_sparkhive_centos7; MAPR_SERVER_IMG=$D_MAPR_SERVER_IMG
D_MAPR_SERVER_TAG=${MAPR_CORE_VER}_${MAPR_MEP_VER}; MAPR_SERVER_TAG=$D_MAPR_SERVER_TAG
#MAPR_SERVER_IMG=mapr_sapvora_centos7     
#MAPR_SERVER_TAG=${MAPR_CORE_VER}_${MAPR_MEP_VER}_${SAP_VORA_VER}
D_MAPR_CLIENT_IMG=mapr_client_centos7; MAPR_CLIENT_IMG=$D_MAPR_CLIENT_IMG
#D_MAPR_CLIENT_TAG=${MAPR_CORE_VER}_${MAPR_MEP_VER}; MAPR_CLIENT_TAG=$D_MAPR_CLIENT_TAG
D_MAPR_CLIENT_TAG=${MAPR_CORE_VER}; MAPR_CLIENT_TAG=$D_MAPR_CLIENT_TAG
#MAPR_LAUNCHER_IMG=mapr_sapvora_launcher_centos7
D_MAPR_LAUNCHER_IMG=mapr_sparkhive_launcher_centos7; MAPR_LAUNCHER_IMG=$D_MAPR_LAUNCHER_IMG
D_MAPR_LAUNCHER_TAG=$D_MAPR_CLIENT_TAG; 
D_MAPR_LAUNCHER=$D_MAPR_LAUNCHER_IMG:$D_MAPR_LAUNCHER_TAG; MAPR_LAUNCHER=$D_MAPR_LAUNCHER
D_SECURE=false; SECURE=$D_SECURE
D_MAPRSEC=false; MAPRSEC=$D_MAPRSEC
D_KERB=false; KERB=$D_KERB
MAPR_SERVER_PKGS_FILE=""
MAPR_CLIENT_PKGS_FILE=""
let MIN_MEMORY=1024*1024*3
D_CLUSTERNAME=my.cluster.com; CLUSTERNAME=$D_CLUSTERNAME
D_NUMBEROFNODES=3; NUMBEROFNODES=$D_NUMBEROFNODES # Number of MapR nodes
D_NUMBEROFCLIENTS=0; NUMBEROFCLIENTS=$D_NUMBEROFCLIENTS # Number of MapR client nodes
D_HIGHAVAILABILITY=false; HIGHAVAILABILITY=$D_HIGHAVAILABILITY
let D_MEMTOTAL=8*1024*1024; MEMTOTAL=$D_MEMTOTAL
let D_MEMCLIENT=2*1024*1024; MEMCLIENT=$D_MEMCLIENT
DISKLISTFILE=""
D_DATAFILESZ=20G
D_DOCKER_VOLUME="/data"
VERBOSE=false
DO_PROMPT=true
INDENT=""

D_KERB_REALM=MAPR.LOCAL; KERB_REALM=$D_KERB_REALM
D_DOMAIN=mapr.local; DOMAIN=$D_DOMAIN
D_HOSTBASE=mapr; HOSTBASE=$D_HOSTBASE
HOSTNUM=0
#DOMAIN=""
SSHOPTS="-o LogLevel=quiet -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
NEXTHOSTNAME=""	# Make sure this is global
#DOCKER_REGISTRY=scale-61:5000
PID=$$
HOSTSFILE=/tmp/hosts.$PID
CLUSHGRPSFILE=/tmp/groups.$PID
PROXY_IMG=squid:latest
KDC_IMG=krb5:1.10.3
#MYSQL_IMG=mysql:5.5
MYSQL_IMG=mariadb:5.5.53
CORE_REPO_IMG=mapr_core_repo:$MAPR_CORE_VER
MEP_REPO_IMG=mapr_mep_repo:$MAPR_MEP_VER
stopRunningContainer=false
clusterNetwork=''
clusterNetwork='mapr_nw'
#dockerExecOpts='-it'
dockerExecOpts=''
AWS_CFT_DOCKER_URL=''
AWS_CFT_MAPR_URL=''

errexit()
{
  echo $(date): ERROR: $@
  if [[ ! -z $AWS_CFT_DOCKER_URL ]] ; then
    echo -n '{"Status" : "FAILURE", "Reason" : "' > /tmp/awsDockerURL.json
    echo -n "$@" >> /tmp/awsDockerURL.json
    echo -n '", "UniqueId" : "errexit", "Data" : "' >> /tmp/awsDockerURL.json
    echo -n "$@" >> /tmp/awsDockerURL.json
    echo '" }' >> /tmp/awsDockerURL.json
    curl -T /tmp/awsDockerURL.json "$AWS_CFT_DOCKER_URL"
  fi
  exit
}

errwarn()
{
  echo $(date): WARN: $@
}

# Docker Checks
if [[ -z $(which docker)  ]] ; then
        echo " docker could not be found on this server. Please install Docker version 1.6.0 or later."
	echo " If it is already installed Please update the PATH env variable." 
        errexit "docker executable not found"
fi

# Wait for docker to start
SLEEPSECS=10
WAITSECS=600
let FINISH=$(date +%s)+$WAITSECS
echo -n "Check for $WAITSECS seconds that docker service is running."
while ! systemctl status docker >/dev/null ; do
  echo -n "."
  [[ $(date +%s) -ge $FINISH ]] && errexit "docker not started after waiting $WAITSECS seconds"
  sleep $SLEEPSECS
done
echo ".OK"

dv=$(docker --version | awk '{ print $3}' | sed 's/,//')
IFS='.' read -ra VERS <<< "$dv"
REQVERS=(1 6 1)
for i in {0..2}; do
    if [[ ${VERS[$i]} -eq ${REQVERS[$i]} ]]; then
      continue
    elif [[ ${VERS[$i]} -gt ${REQVERS[$i]} ]]; then
      break
    else
      echo " Docker version installed on this server : $dv.  Please install Docker version 1.6.0 or later."
      errexit "docker version too old"
    fi
done

usage() {
  echo ""
  [[ ! -z $1 ]] && echo "ERROR: $1"
  echo ""
  echo "$(basename $0) "
  echo "        [ -d DISKLISTFILE |  # File containing list of block devices    (default: -L $D_DOCKER_VOLUME)"
  echo "          -L DOCKER_VOLUME ] # Docker volume mount to use for MapR data (default: $D_DOCKER_VOLUME )"
  echo "        [ -c CLUSTERNAME ]   # MapR cluster name                        (default: $D_CLUSTERNAME)"
  echo "        [ -I CLIENT_IMG ]    # Docker client image                      (default: $D_MAPR_CLIENT_IMG)"
  echo "        [ -T CLIENT_TAG ]    # Docker client image tag                  (default: $D_MAPR_CLIENT_TAG)"
  echo "        [ -P CLIENT_PKGS ]   # MapR Client packages - one line per node (default: None)"
  echo "                               0 default client package list (space separated)"
  echo "                                 Only used if -n option specifies more than N client nodes"
  echo "                               1 first client node package list (space separated)"
  echo "                               N Nth client node package list (space separated)"
  echo "                               Example client_pkgs.txt:"
  echo "                                 0 posix-client-basic"
  echo "                                 1 hive pig"
  echo "                                 2 spark"
  echo "        [ -m SERVER_MEMORY ] # Memory per MapR server container (KB)    (default: $D_MEMTOTAL)"
  echo "        [ -M CLIENT_MEMORY ] # Memory per client container (KB)         (default: $D_MEMCLIENT)"
  echo "        [ -N CLIENT_NODES ]  # Number of MapR client nodes              (default: $D_NUMBEROFCLIENTS)"
  echo "        [ -i SERVER_IMG ]    # Docker server image                      (default: $D_MAPR_SERVER_IMG)"
  echo "        [ -t SERVER_TAG ]    # Docker server image tag                  (default: $D_MAPR_SERVER_TAG)"
  echo "        [ -n SERVER_NODES ]  # Number of MapR server nodes              (default: $D_NUMBEROFNODES)"
  echo "        [ -p SERVER_PKGS ]   # MapR Server packages file - one line per node (default: None)"
  echo "                               0 default server package list (space separated)"
  echo "                                 Only used if -N option specifies more than N MapR server nodes"
  echo "                               1 first server node package list (space separated)"
  echo "                               N Nth server node package list (space separated)"
  echo "                               Example server_pkgs.txt:"
  echo "                                 0 fileserver nodemanager"
  echo "                                 1 fileserver nodemanager cldb"
  echo "                                 2 fileserver nodemanager zookeeper"
  echo "                                 3 fileserver nodemanager webserver resourcemanager"
  echo "                                 4 fileserver nodemanager hiveserver2 hivemetastore"
  echo "        [ -D DOMAIN ]        # Cluster network domain                   (default: $D_DOMAIN)"
  echo "        [ -K REALM ]         # Kerberos REALM (implies -k)              (default: $D_KERB_REALM)"
  echo "        [ -H HOSTBASE ]      # Base string for hostnames)               (default: $D_HOSTBASE)"
  echo "        [ -s | -k ]          # -s Use Mapr Security                     (default: $D_MAPRSEC)"
  echo "                             # -k Use Kerberos Security                 (default: $D_KERB)"
  echo "        [ -u DockerURL ]     # AWS CloudFormation URL to pass docker container startup status"
  echo "        [ -U MapRURL ]       # AWS CloudFormation URL to pass MapR cluster startup status"
  echo "        [ -y ]               # Answer yes to questions (WARNING: Formats disks without prompt)"
  echo "        [ -v ]               # Verbose"
  echo "        [ -h ]               # Print help message"
  echo "        [ -l LAUNCHER ]      # Docker launcher (image and tag)          (default: $D_MAPR_LAUNCHER)"
  echo "        [ -C file ]          # File to copy to /home/mapr in launcher	(multiple -C options OK)"
  echo "                             #   If argument is a directory, equivalent to a -C for each file in directory"
  echo "                             #   Typically used to pass in start-cluster-[other|custom].[sh|functions]"
  echo "                             #   Can also be used to overwrite start-cluster.sh script in the launcher image"
  echo ""
}

declare -a fileArr
declare -a dockerAddHostArgsArr
declare -a dockerProxyAddHostArgsArr
declare -a auxImageArr
while getopts ":a:A:c:C:d:D:hH:i:I:kK:l:L:m:M:n:N:p:P:sS:t:T:u:U:vy" OPTION
do
  case $OPTION in
    # -A option launches an auxiliary container usable for multiple clusters (eg yum repo)
    # -a option launches an auxiliary container for the given cluster
    # If a different version (tag) of the container is already running, it is stopped.
    # Format is Image:Tag
    a)
      auxClusterImageArr+=($OPTARG)
      ;;
    A)
      auxGlobalImageArr+=($OPTARG)
      ;;
    c)
      CLUSTERNAME=$OPTARG
      ;;
    C)
      fileArr+=($OPTARG)
      ;;
    d)
      DISKLISTFILE=$OPTARG
      ;;
    D)
      DOMAIN=$OPTARG
      ;;
    H)
      HOSTBASE=$OPTARG
      ;;
    i)
      MAPR_SERVER_IMG=$OPTARG
      ;;
    I)
      MAPR_CLIENT_IMG=$OPTARG
      ;;
    K)
      KERB_REALM=$OPTARG
      KERB=true
      SECURE=true
      ;;
    k)
      KERB=true
      SECURE=true
      ;;
    l)
      MAPR_LAUNCHER=$OPTARG
      ;;
    L)
      DOCKER_VOLUME=$OPTARG
      ;;
    m)
      MEMTOTAL=$OPTARG
      ;;
    M)
      MEMCLIENT=$OPTARG
      ;;
    n)
      NUMBEROFNODES=$OPTARG
      ;;
    N)
      NUMBEROFCLIENTS=$OPTARG
      ;;
    p)
      MAPR_SERVER_PKGS_FILE=$OPTARG
      ;;
    P)
      MAPR_CLIENT_PKGS_FILE=$OPTARG
      ;;
    s)
      MAPRSEC=true
      SECURE=true
      ;;
    t)
      MAPR_SERVER_TAG=$OPTARG
      ;;
    T)
      MAPR_CLIENT_TAG=$OPTARG
      ;;
    u)
      AWS_CFT_DOCKER_URL="$OPTARG"
      ;;
    U)
      AWS_CFT_MAPR_URL="$OPTARG"
      ;;
    y)
      DO_PROMPT=false
      ;;
    v)
      VERBOSE=true
      ;;
    h)
      usage
      exit
      ;;
    *)
      usage "Invalid argument: $OPTARG"
      errexit "Invalid argument: $OPTARG"
      ;;
  esac
done

shift $((OPTIND-1))

$VERBOSE && echo "Running command: $commandLine"
echo "$commandLine" > /tmp/launch-cluster.cmdline

[[ ! -z $1 ]] && errexit "Invalid extra argument(s): $@"

declare -a disks

if [[ -z $DISKLISTFILE ]] ; then
  [[ -z $DATAFILESZ ]] && DATAFILESZ=$D_DATAFILESZ
  [[ -z $DOCKER_VOLUME ]] && DOCKER_VOLUME=$D_DOCKER_VOLUME
  echo "Using docker volume $DOCKER_VOLUME with $DATAFILESZ maprdatafile"
  i=$NUMBEROFNODES
  while [[ $i -gt 0 ]]; do
    disks+=( $DOCKER_VOLUME/maprdatafile )
    let i--
  done
else
  if [[ ! -z $DOCKER_VOLUME ]]; then usage "Select one of -d and -L, not both"; errexit "only one of -d and -L options may be specified"; fi
  if [[ ! -f ${DISKLISTFILE} ]]
  then
    echo "Specified disklistfile: '" $DISKLISTFILE "' doesn't exist"
    errexit "disklistfile $DISKLISTFILE does not exist"
  fi

  disks=( $(cat ${DISKLISTFILE}) )
  
  if [[ ${#disks[@]} -eq 0 ]] 
  then
    errexit "no usable disks specified in $DISKLISTFILE"
  fi

  if [[ ${#disks[@]} -lt ${NUMBEROFNODES} ]] ; then
    echo " Not enough disks to run the requested configuration. "
    echo " $DISKLISTFILE specifies ${#disks[@]} disks : ${disks[@]}"
    echo " $NUMBEROFNODES nodes were requested.  Each node requires a minimum of one disk."
    errexit "only ${#disks[@]} disks specified for $NUMBEROFNODES MapR nodes"
  fi
  
  if [[ -f ${DISKLISTFILE} ]]; then
    echo "THESE DRIVES WILL BE FORMATTED BY MapR.  ANY EXISTING DATA WILL BE DESTROYED."
    cat $DISKLISTFILE
    response="Y"
    echo -n "CONTINUE [y/N]? "
    if $DO_PROMPT; then
      [[ ! -z $AWS_CFT_DOCKER_URL ]] && errexit "-y option must be specified for non-interactive mode"
      read -n 1 response
    fi
    echo ""
    if [[ ! $response =~ [yY] ]]; then
      echo "Launch aborted.  No containers created."
      exit
    fi
  fi
fi

nextdisk=0
let disksPerNode=${#disks[@]}/${NUMBEROFNODES} # Same number of disks per node.  Discard remainder.

# Memory check

let systemMB=$(cat /proc/meminfo | grep MemTotal | tr -s ' ' | cut -f2 -d ' ' )/1024
let serverMB=$MEMTOTAL/1024
let totalServerMB=$serverMB*$NUMBEROFNODES
let clientMB=$MEMCLIENT/1024
let totalClientMB=$clientMB*$NUMBEROFCLIENTS
let subscribedMB=$serverMB*$NUMBEROFNODES+$clientMB*$NUMBEROFCLIENTS

if [[ $subscribedMB -gt $systemMB ]]; then
  [[ $NUMBEROFCLIENTS -gt 0 ]] && clientsMessage="and $NUMBEROFCLIENTS clients with ${clientMB}MB "
  echo "Memory is oversubscribed."
  echo "  $NUMBEROFNODES MapR server nodes with ${serverMB}MB ${clientsMessage}is greater than system memory ${systemMB}MB"
  echo -n "  Continue anyway? [Y/n] "
  response="Y"
  if $DO_PROMPT; then
    [[ ! -z $AWS_CFT_DOCKER_URL ]] && errexit "-y option must be specified for non-interactive mode"
    read -n 1 response
  fi
  echo ""
  if [[ $response =~ [nN] ]]; then
    echo "Launch aborted.  No containers created."
    exit 
  fi
fi

declare -a maprServerPkgs
if [[ ! -z $MAPR_SERVER_PKGS_FILE ]]; then
  if [[ -f $MAPR_SERVER_PKGS_FILE ]]; then
    i=0
    while read line; do
      line=${line%%#*}
      [[ -z "$line" ]] && continue
      set -- $line
      idx=$1
      shift
      pkgs="$@"
      maprServerPkgs[$idx]="$pkgs"
    done < $MAPR_SERVER_PKGS_FILE
  else
    errexit "MapR server packages file $MAPR_SERVER_PKGS_FILE is not a regular file"
  fi
fi

declare -a maprClientPkgs
if [[ ! -z $MAPR_CLIENT_PKGS_FILE ]]; then
  if [[ -f $MAPR_CLIENT_PKGS_FILE ]]; then
    i=0
    while read line; do
      line=${line%%#*}
      [[ -z "$line" ]] && continue
      set -- $line
      idx=$1
      shift
      pkgs="$@"
      maprClientPkgs[$idx]="$pkgs"
    done < $MAPR_CLIENT_PKGS_FILE
  else
    errexit "MapR client packages file $MAPR_CLIENT_PKGS_FILE is not a regular file"
  fi
fi

if [[ $MEMTOTAL -lt $MIN_MEMORY ]]; then
  echo "Memory per image: '" $MEMTOTAL "' less than required $MIN_MEMORY"
  errexit "$MEMTOTAL KB less than required $MIN_MEMORY KB"
fi
let MEMFREE=$MEMTOTAL-10
let MEMAVAIL=$MEMTOTAL-10


if [[ ${NUMBEROFNODES} -lt 1 ]] ; then
	echo "At least 1 node is required.  '" $NUMBEROFNODES "' nodes were specified"
	exit
fi

$MAPRSEC && $KERB && usage "Select only one of MapR or Kerberos security with -s and -k" && errexit "only one of -s and -k options may be specified"

# Check to see if CLUSTERNAME is in use
clusterNameDash="${CLUSTERNAME//./-}" # Replace periods with hyphens. Used for hostname to ensure proper domain setting.
clusterNameDash="${clusterNameDash//_/-}" # Replace underscore with hyphens. Used for hostname to ensure valid hostname setting.

runningClusters=$(docker ps -a --format "{{.Names}}:{{.Status}}" | grep '\-s1:' | grep ':Up' | grep -v '(Paused)' | sed "s/-s1:.*$//")
stoppedClusters=$(docker ps -a --format "{{.Names}}:{{.Status}}" | grep '\-s1:' | grep -v ':Up' | sed "s/-s1:.*$//")
pausedClusters=$(docker ps -a --format "{{.Names}}:{{.Status}}" | grep '\-s1:' | grep '(Paused)' | sed "s/-s1:.*$//")

clusterArr=( $runningClusters $stoppedClusters $pausedClusters )

for nextCluster in ${clusterArr[@]}; do
  if [[ $nextCluster = $clusterNameDash ]]; then
    usage "Cluster name $CLUSTERNAME already in use." && errexit "cluster name $CLUSTERNAME already in use"
  fi
done

startClusterOpts="-c $CLUSTERNAME -D $DOMAIN"
$MAPRSEC && startClusterOpts+=" -s"
[[ ! -z $AWS_CFT_MAPR_URL ]] && startClusterOpts+=" -U '$AWS_CFT_MAPR_URL'"
$VERBOSE && startClusterOpts+=" -v"
$DEBUG && startClusterOpts+=" -d"

#declare -a container_ids
# Array of MapR cluster container info (IP:HOSTNAME:DOMAINNAME:CONTAINERNAME:CONTAINERID:SSHPORT)
declare -a maprContainerInfoArr
# Array of Auxiliary container info (IP:HOSTNAME:DOMAINNAME:CONTAINERNAME:CONTAINERID:SSHPORT)
declare -a auxContainerInfoArr

declare -a container_ips
declare -a ocontainer_ips
declare -a container_hns
declare -a ocontainer_hns
declare -a container_ssh
declare -a ocontainer_ssh
declare -a IMAGE_ENV
declare -a CLDB_HOSTS
declare -a ZOOKEEPER_HOSTS
declare -a SERVICE_LIST

# Need bash 4 for associative array.
# On Mac OSX, must install bash 4.
# Use MacPorts as below or Homebrew
# 1. sudo port install bash
# 2. Add /opt/local/bin/bash to /etc/shells
# 3. chsh -s /opt/local/bin/bash
# TBD: REWRITE using standard bash array
#      See Enum for containerinfo indexes

declare -A clushRoleArr
declare -a ipAddrArr # entries are hostname:ip


# Enum create indexes into '|' separated container info in xxxContainerInfoArr
CONTAINERINFO=(cntrIP cntrHOST cntrDOMAIN cntrNAME cntrID)
tam=${#CONTAINERINFO[@]}
for ((i=0; i < $tam; i++)); do
  name=${CONTAINERINFO[$i]}
  declare -r ${name}=$i
done

docker_container_exists()
{
  INDENT="$INDENT  "
  containerNameOrId=$1
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }

  docker inspect $containerNameOrId > /dev/null 2>&1
}

docker_container_on_network()
{
  local container=$1
  local network=$2
  if docker_container_exists $container; then
    docker inspect --format "{{ .NetworkSettings.Networks.$network }}" $container | grep -v 'no value' > /dev/null 2>&1
  else
    false
  fi
}

docker_container_running() 
{
  INDENT="$INDENT  "
  containerNameOrId=$1
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }

  containerRunning=$(docker inspect --format '{{ .State.Running }}' $containerNameOrId 2> /dev/null)
  if [[ $containerRunning = "true" ]]; then
    return 0
  elif [[ $containerRunning = "false" ]]; then
    return 1
  else
    errwarn "No such container $containerNameOrId"
    return 1
  fi
}

docker_have_info()
{
  INDENT="$INDENT  "
  containerNameOrId=$1
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }

  for containerInfo in ${maprContainerInfoArr[@]} ${auxContainerInfoArr[@]}; do
    IFS='|' read -ra containerInfoArr <<< "$containerInfo"
    [[ $containerNameOrId == ${containerInfoArr[$cntrNAME]} ]] && return 0
    # Docker container name has a leading slash when inspected
    [[ $containerNameOrId == ${containerInfoArr[$cntrNAME]#/} ]] && return 0
    [[ $containerNameOrId == ${containerInfoArr[$cntrID]} ]] && return 0
  done
  return 1
}

get_env_var()
{
  local containerNameOrId=$1
  local envVar=$2
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }

  for nextVar in $(docker inspect --format '{{ .Config.Env }}' $containerNameOrId | tr -s '[]' ' '); do 
    if echo $nextVar | grep ^${envVar}= > /dev/null ; then
      echo ${nextVar#*=}
      break
    fi 
  done
}

getIP()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }

  local hostname=$1
  local nextHost
  for nextHost in ${ipAddrArr[@]}; do
    if [[ ${nextHost%%:*} = $hostname ]]; then
      echo ${nextHost##*:}
      return 
    fi
  done
}

docker_set_info()
{
  local containerNameOrId=$1
  local hostName
  local domainName
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2

  # If -h hostname in docker run command contains a fqdn, docker on Mac puts the entire fqdn in .Config.Hostname
  # On linux, docker splits it into .Config.Hostname and .Config.Domainname
  # 6/5/2017:  Docker 1.12 has Mac behavior in linux now also.  
  # This fix for the Mac will separate the two out

  hostName="$(docker inspect --format '{{ .Config.Hostname }}' $containerNameOrId )" 
  domainName="$(docker inspect --format '{{ .Config.Domainname }}' $containerNameOrId )" 
  if [[ -z $domainName ]]; then domainName=${hostName#*.} ; fi
  hostName=${hostName%%.*}

  #clusterNetwork=mapr_nw
  printf -v containerInfo "%s|%s|%s|%s|%s" \
    $(docker inspect --format "{{ .NetworkSettings.Networks.$clusterNetwork.IPAddress }}" $containerNameOrId ) \
    "$hostName" \
    "$domainName" \
    "$(docker inspect --format '{{ .Name }}' $containerNameOrId )" \
    "$(docker inspect --format '{{ .Id }}' $containerNameOrId )" 


  nodeType=$(get_env_var $containerNameOrId NODETYPE)
  if [[ $nodeType == "MapRServer" ]] || [[ $nodeType == "MapRClient" ]] ; then
    maprContainerInfoArr+=($containerInfo)
  else
    auxContainerInfoArr+=($containerInfo)
  fi
  INDENT=${INDENT%  }
}

list_aux_container_ids()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }
  for containerInfo in ${auxContainerInfoArr[@]}; do
    IFS='|' read -ra containerInfoArr <<< "$containerInfo"
    echo ${containerInfoArr[$cntrID]}
  done
}

docker_get_info()
{
  local containerNameOrId=$1
  local infoIdx=$2
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }

  for containerInfo in ${maprContainerInfoArr[@]} ${auxContainerInfoArr[@]}; do
    IFS='|' read -ra containerInfoArr <<< "$containerInfo"
    if [[ $containerNameOrId == ${containerInfoArr[$cntrNAME]} ]] || \
       [[ $containerNameOrId == ${containerInfoArr[$cntrNAME]#/} ]] || \
       [[ $containerNameOrId == ${containerInfoArr[$cntrID]} ]] ; then
      if [[ -z $infoIdx ]] ; then 
        echo $containerInfo
      else
        echo ${containerInfoArr[$infoIdx]}
      fi
    fi
  done
}

create_hosts_file()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  rm -f $HOSTSFILE
  touch $HOSTSFILE
  for containerInfo in ${maprContainerInfoArr[@]} ${auxContainerInfoArr[@]}; do
    IFS='|' read -ra containerInfoArr <<< "$containerInfo"
    ip=${containerInfoArr[$cntrIP]}
    hn=${containerInfoArr[$cntrHOST]}
    fqdn=$hn
    dm=${containerInfoArr[$cntrDOMAIN]}
    if [[ ! -z $dm ]] ; then
      fqdn+=".$dm"
    fi
    printf "%-16s %-30s %-10s\n" $ip $fqdn $hn >> $HOSTSFILE
  done
  sort -V $HOSTSFILE > /tmp/tmpfile.$$
  mv -f /tmp/tmpfile.$$ $HOSTSFILE
  INDENT=${INDENT%  }
}

create_clush_groups_file()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  rm -f $CLUSHGRPSFILE
  touch $CLUSHGRPSFILE
  clushRoleArr[all]="all: "
  clushRoleArr[client]="client: "
  clushRoleArr[cluster]="$CLUSTERNAME: "
  clushRoleArr[aux]="aux: "
  for containerInfo in ${maprContainerInfoArr[@]} ; do
    IFS='|' read -ra containerInfoArr <<< "$containerInfo"
    containerId=${containerInfoArr[$cntrID]}
    #nodeType=$(docker inspect $containerId | jq -r '.[]|.Config.Env|.[]' | grep ^NODETYPE= | cut -f2 -d'=')
    nodeType=$(get_env_var $containerId NODETYPE)
    hn=${containerInfoArr[$cntrHOST]}
    clushRoleArr[all]+=${hn},
    if [[ $nodeType == "MapRServer" ]] ; then
      clushRoleArr[cluster]+=${hn},
    fi
    if [[ $nodeType == "MapRClient" ]] ; then
      clushRoleArr[client]+=${hn},
    fi
  done
  for containerInfo in ${auxContainerInfoArr[@]}; do
    IFS='|' read -ra containerInfoArr <<< "$containerInfo"
    hn=${containerInfoArr[$cntrHOST]}
    clushRoleArr[aux]+=${hn},
  done

  for nextGroup in "${clushRoleArr[@]}" ; do
    echo "${nextGroup%,}" >> $CLUSHGRPSFILE
  done
  INDENT=${INDENT%  }
}

# Back up existing remove_cluster script
[[ -f /tmp/remove_cluster_${CLUSTERNAME}.sh ]] && mv /tmp/remove_cluster_${CLUSTERNAME}.sh /tmp/remove_cluster_${CLUSTERNAME}.sh.bak
rm -f /tmp/remove_cluster_${CLUSTERNAME}.sh && touch /tmp/remove_cluster_${CLUSTERNAME}.sh && chmod +x /tmp/remove_cluster_${CLUSTERNAME}.sh
rm -f /tmp/remove_aux.sh && touch /tmp/remove_aux.sh && chmod +x /tmp/remove_aux.sh

cleanup() {
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  rm -f $HOSTSFILE
  rm -f $CLUSHGRPSFILE
  INDENT=${INDENT%  }
}

function join { local IFS="$1"; shift; echo "$*"; }

# Return true if port is already in use
portinuse() {
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }
  netstat -lntup | grep ':' | tr -s ' ' | cut -f 4 -d ' ' | grep ":${1}\$"
}

# Pass in Docker image:tag as first parameter and addl docker run options after that
# Passes in IMAGE_ENV array settings as -e environment variables

nextMapRServer=1
nextMapRClient=1
start_container()
{
  local i
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2

  DOCKER_IMAGE=$1
  [[ ! -z $DOCKER_REGISTRY ]] && DOCKER_IMAGE=$DOCKER_REGISTRY/$DOCKER_IMAGE
  shift
  DOCKER_ARGS="$@"
  networkSpecified=false
  if [[ "$DOCKER_ARGS" =~ "--network " ]]; then
    networkSpecified=true
  fi
  # Parse DOCKER_ARGS for -h or --hostname and set NEXTHOSTNAME for later lookup of IP address for docker run
  while [[ ! -z $1 ]]; do
    if [[ $1 = "-h" ]] || [[ $1 = "--hostname" ]]; then
      shift
      NEXTHOSTNAME=$1
      shift
    fi
    shift
  done
 
  IMAGE_ENV_CL=""
  if [[ ! -z $IMAGE_ENV ]]; then
    i=0
    while [[ $i -lt ${#IMAGE_ENV[@]} ]]; do
      IMAGE_ENV_CL+=" -e ${IMAGE_ENV[$i]}"
      let i++
    done
  fi
  #nodeType=$(docker inspect $DOCKER_IMAGE | jq -r '.[]|.Config.Env|.[]' | grep ^NODETYPE= | cut -f2 -d'=')
  nodeType=$(get_env_var $DOCKER_IMAGE NODETYPE)
  dockerHostNameArg=""
  if [[ $nodeType == "MapRServer" ]] || [[ $nodeType == "MapRClient" ]] ; then
    let HOSTNUM++ 
    NEXTHOSTNAME=${HOSTBASE}$(printf "%02d" $HOSTNUM)
    [[ ! -z $DOMAIN ]] && NEXTHOSTNAME+=".$DOMAIN"
    dockerHostNameArg="-h $NEXTHOSTNAME"

    if [[ $nodeType == "MapRServer" ]] ; then
      [[ ! -z $DOCKER_VOLUME ]] && DOCKER_VOLUME_OPT="-v $DOCKER_VOLUME"
    fi
  fi

  [[ -z $NEXTHOSTNAME ]] && errexit "NEXTHOSTNAME not set $DOCKER_IMAGE $DOCKER_ARGS"

  # ipAddr=$(docker_next_ip mapr_nw)
  ipAddr=$(getIP $NEXTHOSTNAME)
  [[ -z $ipAddr ]] && errexit "No IP Addr for $NEXTHOSTNAME in ${ipAddrArr[@]}"
  if ! $networkSpecified ; then
    DOCKER_ARGS+=" --network mapr_nw --ip $ipAddr "
  fi
  DOCKER_ARGS+=" --restart always "

  if [[ "$DOCKER_IMAGE" = "$PROXY_IMG" ]]; then
    echo "docker run -d ${dockerAddHostArgsArr[@]} ${dockerProxyAddHostArgsArr[@]} $dockerHostNameArg $DOCKER_ARGS $DOCKER_VOLUME_OPT $IMAGE_ENV_CL $DOCKER_IMAGE"
    containerId=$(docker run -d "${dockerAddHostArgsArr[@]}" "${dockerProxyAddHostArgsArr[@]}" $dockerHostNameArg $DOCKER_ARGS $DOCKER_VOLUME_OPT $IMAGE_ENV_CL $DOCKER_IMAGE)
  else
    echo "docker run -d ${dockerAddHostArgsArr[@]} $dockerHostNameArg $DOCKER_ARGS $DOCKER_VOLUME_OPT $IMAGE_ENV_CL $DOCKER_IMAGE"
    containerId=$(docker run -d "${dockerAddHostArgsArr[@]}" $dockerHostNameArg $DOCKER_ARGS $DOCKER_VOLUME_OPT $IMAGE_ENV_CL $DOCKER_IMAGE)
  fi
  [[ -z $containerId ]] && errexit "docker run command failed"
  echo "docker rm -vf $containerId & " >> /tmp/remove_cluster_${CLUSTERNAME}.sh
  #CONTAINERINFO=(cntrIP cntrHOST cntrDOMAIN cntrNAME cntrID)

  # AML test sleep 10
  while ! docker_container_running $containerId; do
    sleep 1
  done

  docker_set_info $containerId
  ip=$(docker_get_info $containerId $cntrIP)
  hn=$(docker_get_info $containerId $cntrHOST)
  dm=$(docker_get_info $containerId $cntrDOMAIN)
  nm=$(docker_get_info $containerId $cntrNAME)
  contEnv=$(docker inspect --format '{{ .Config.Env }}' ${containerId} )
  #nodeType=$(docker inspect ${containerId} | jq -r '.[]|.Config.Env|.[]' | grep ^NODETYPE= | cut -f2 -d'=')
  nodeType=$(get_env_var $containerId NODETYPE)
  #sshPort=$(docker inspect ${containerId} | jq -r '.[]|.NetworkSettings.Ports."22/tcp"[].HostPort')

  hostAlias=${nm#/}; hostAlias=${hostAlias##*_}
  printf "%-16s %s %s %s\n" $ip ${hn}.${dm} $hn $hostAlias >> $HOSTSFILE
  
  
  #container_ips[0]=$cldbip
  if [[ $nodeType == "MapRServer" ]] || [[ $nodeType == "MapRClient" ]] ; then
    echo "docker rm -vf $containerId & " >> /tmp/remove_cluster_${CLUSTERNAME}.sh
    [[ $hn != ${NEXTHOSTNAME%%.*} ]] && errexit "Docker container $containerId inspect Hostname $hn unequal to assigned hostname ${NEXTHOSTNAME%%.*}"
    [[ $dm != ${NEXTHOSTNAME#*.} ]] && errexit "Docker container $containerId inspect Domain $dm unequal to assigned domain ${NEXTHOSTNAME#*.}"
  else
    # Set NEXTHOSTNAME for Auxiliary servers that had hostname passed in as a docker run argument or just defaulted
    NEXTHOSTNAME="$hn.$dm"
    #ocontainer_ips+=($ip)
    #ocontainer_hns+=($NEXTHOSTNAME)
    #ocontainer_ssh+=($sshPort)
  fi
  
  # For MapR Server or Client nodes, set up mep repository to local container if it isn't already set (by child container)
  # e.g. mapr_server_centos7 does not have mep version configured but mapr_sparkhive_centos7 does
  if [[ $nodeType == "MapRServer" ]] || [[ $nodeType == "MaprClient" ]]; then
    docker exec $dockerExecOpts $containerId bash -c "[[ -f /etc/yum.repos.d/mapr_mep.repo.template ]] && \
      [[ ! -f /etc/yum.repos.d/mapr_mep.repo ]] && \
      sed -e"s/MAPR_MEP_VER/$MAPR_MEP_VER/" /etc/yum.repos.d/mapr_mep.repo.template > /etc/yum.repos.d/mapr_mep.repo"
  fi

  if [[ $nodeType == "MapRServer" ]] ; then
    docker exec $dockerExecOpts $containerId bash -c "printf '%-13s%11d %s\n' 'MemTotal:' ${MEMTOTAL} 'kB' > /opt/mapr/conf/meminfofake"
    docker exec $dockerExecOpts $containerId bash -c "printf '%-13s%11d %s\n' 'MemFree:' ${MEMFREE} 'kB' >> /opt/mapr/conf/meminfofake"
    docker exec $dockerExecOpts $containerId bash -c "printf '%-13s%11d %s\n' 'MemAvailable:' ${MEMAVAIL} 'kB' >> /opt/mapr/conf/meminfofake"
    docker exec $dockerExecOpts $containerId bash -c "cat /proc/meminfo  | grep -v MemTotal | grep -v MemAvailable | grep -v MemFree >> /opt/mapr/conf/meminfofake"
    docker exec $dockerExecOpts $containerId bash -c "/opt/mapr/server/mruuidgen > /opt/mapr/hostid"
##
    docker exec $dockerExecOpts $containerId bash -c "systemctl stop mapr-warden"
    i=0
    while [[ $i -lt $disksPerNode ]] ; do
      docker exec $dockerExecOpts $containerId bash -c "echo ${disks[$nextdisk]} >> /home/mapr/disks.txt"
      let nextdisk++
      let i++
    done
    idx=0
    if [[ $nextMapRServer -lt ${#maprServerPkgs[@]} ]]; then
      idx=$nextMapRServer
    fi
    if [[ ! -z ${maprServerPkgs[$idx]} ]] ; then
      docker exec $dockerExecOpts $containerId bash -c "echo ${maprServerPkgs[$idx]} > /home/mapr/mapr_packages.txt"
    fi
    for maprRole in ${maprServerPkgs[$idx]} ; do
      if [[ -z ${clushRoleArr[$maprRole]} ]] ; then
        clushRoleArr[$maprRole]="${maprRole}: $hn"
      else
        clushRoleArr[$maprRole]+=",$hn"
      fi
    done
    let nextMapRServer++
  fi
  if [[ $nodeType == "MapRClient" ]] ; then
    idx=0
    if [[ $nextMapRClient -lt ${#maprClientPkgs[@]} ]]; then
      idx=$nextMapRClient
    fi
    if [[ ! -z ${maprClientPkgs[$idx]} ]] ; then
      docker exec $dockerExecOpts $containerId bash -c "echo ${maprClientPkgs[$idx]} > /home/mapr/mapr_packages.txt"
    fi
    for maprRole in ${maprClientPkgs[$idx]} ; do
      if [[ -z ${clushRoleArr[$maprRole]} ]] ; then
        clushRoleArr[$maprRole]="${maprRole}: $hn"
      else
        clushRoleArr[$maprRole]+=",$hn"
      fi
    done
    let nextMapRClient++
  fi
  #container_ips+=($ip)
  #container_hns+=($NEXTHOSTNAME)
  #container_ssh+=($sshPort)

#AML Move this to a startup file in the container.  Start all containers then let launch clush -aB /tmp/startup.sh
  #if [[ ! -z $SERVICE_LIST ]]; then
  #  docker exec $dockerExecOpts $containerId bash -c "yum --disablerepo="*" --enablerepo=MapR_Core install -y ${SERVICE_LIST[@]}"
  #fi

  echo "Docker Image $DOCKER_IMAGE started as $NEXTHOSTNAME $ip"
  
  unset IMAGE_ENV
  unset SERVICE_LIST
  INDENT=${INDENT%  }
}

mysql_required()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  # TBD: Add logic to see if any services that require mysql are in service list (hivemeta, oozie, hue)
  INDENT=${INDENT%  }
  true;
}

docker_network_exists()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }
  [[ ! -z $(docker network ls -q --filter "name=$1") ]]
}

docker_next_subnet()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  # Print the subnet in CIDR format of the next available /16 docker bridge network

  bridgeNetworks="$(docker network ls --filter 'driver=bridge' -q)"
  IFS='.' read -ra netCIDR <<< "$(for NETWORK in $bridgeNetworks ; do \
                                    docker network inspect $NETWORK | \
                                      jq -r '.[].IPAM.Config[0].Subnet' ; \
                                  done | sort -n | tail -1)"
  let netCIDR[1]++
  echo ${netCIDR[@]} | tr ' ' '.'
  INDENT=${INDENT%  }
}

docker_network_create()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  # Given a network name, create it if it doesn't already exist

  # In order to specify an IP address when running a docker container, a subnet must be specified when
  # creating a network.  Seems like a docker bug but specifying --subnet works around it.
  if ! docker_network_exists $1; then
    dockerGW=$(docker_next_subnet | sed -e 's^0/16^1^')
    docker network create --driver bridge $1 --subnet $(docker_next_subnet) --gateway $dockerGW
  fi
  INDENT=${INDENT%  }
}

docker_network_subnet()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }
  # Given a network name, print the CIDR subnet of that network

  networkID=$(docker network ls --filter "name=$1" -q)
  docker network inspect $networkID | jq -r '.[].IPAM.Config[0].Subnet'
}
  
docker_next_ip()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  local nextContainer
  local ip
  local lastOctet
  local nw
  local IPAddr
  nw=$1
  # Given a docker network, return the next available IP address on that network
  lastNetworkIP=$(docker network inspect $nw  | jq -r '.[].Containers[].IPv4Address'  | sort --version-sort | tail -1 | sed -e 's^/.*$^^')
  #if [[ -z lastContainerIP ]]; then
  if [[ -z $lastNetworkIP ]]; then
    # Arbitrarily start network addresses with last octet at 100 
    lastNetworkIP=$(docker_network_subnet $nw | sed -e 's^0/16^100^')
  fi
  # TBD:  Check for stopped containers on the network and if greater than $lastNetworkIP, then use that for lastNetworkIP
  # for nextContainer in stopped_containers; do
  #   clusterNetwork=mapr_nw
  #   ip=$(docker inspect --format "{{ .NetworkSettings.Networks.$clusterNetwork.IPAddress }}" $containerNameOrId ) \
  
  #   if lastOctet of $ip > lastOctet of lastContainerIP; then
  #     lastContainerIP=$ip
  #   fi
  # done 
  for containerNameOrId in $(docker ps -qa); do 
    ip=$(docker inspect --format "{{ .NetworkSettings.Networks.$nw.IPAMConfig.IPv4Address }}" $containerNameOrId)
    [[ "$ip" =~ "no value" ]] && continue
    if [[ ${ip##*.} -gt ${lastNetworkIP##*.} ]]; then
      lastNetworkIP=$ip
    fi
  done

  IFS='.' read -ra IPAddr <<< "$lastNetworkIP"
  let IPAddr[3]++
  echo ${IPAddr[@]} | tr ' ' '.'
  INDENT=${INDENT%  }
}

add_host()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  INDENT=${INDENT%  }
  host=$1
  useIP=$2
  local subnet
  local ip
  local lastOctet
  local nextUnusedIP
  local greatestOctet=0
  [[ -z $host ]] && errexit "add_host requires host parameter"
  if [[ ! -z $useIP ]]; then
    ipAddrArr+=("${host}:${useIP}")
    return
  fi

  if [[ ${#ipAddrArr[@]} -eq 0 ]]; then
    ipAddrArr+=("${host}:$(docker_next_ip mapr_nw)")
  else
    # increment greatest last octet
    for ip in ${ipAddrArr[@]}; do
      ip=${ip##*:}
      subnet=${ip%.*}
      lastOctet=${ip##*.}
      [[ $lastOctet -gt $greatestOctet ]] && greatestOctet=$lastOctet
    done
    lastOctet=${greatestOctet}
    let lastOctet+=1
    ip=${subnet}.${lastOctet}

    # Be sure you aren't overwriting an existing IP address on the network
    nextUnusedIP=$(docker_next_ip mapr_nw)
    if [[ ${nextUnusedIP##*.} -gt $lastOctet ]]; then
      ip=$nextUnusedIP
    fi
    ipAddrArr+=("${host}:${ip}")
  fi
}

setup_mapr_ips()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  local count
  local hostnum
  local nexthostname
  let hostnum=0
  let count=$NUMBEROFNODES+$NUMBEROFCLIENTS+1
  while [[ $hostnum -lt $count ]]; do
    let hostnum++ 
    nexthostname=${HOSTBASE}$(printf "%02d" $hostnum)
    [[ ! -z $DOMAIN ]] && nexthostname+=".$DOMAIN"
    add_host $nexthostname
  done
  INDENT=${INDENT%  }
}

# auxContainerList must be the same for both set_aux_ips and start_aux_containers so use this varialbe
auxContainerList="${CLUSTERNAME}-mapr-mysql ${CLUSTERNAME}-mapr-kdc mapr-webproxy mapr-core-repo mapr-mep-repo ${auxClusterImageArr[@]} ${auxGlobalImageArr[@]}"

setup_aux_ips()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  # Set up IP Addresses
  local ip=""	
  #for auxContainer in ${CLUSTERNAME}-mapr-mysql ${CLUSTERNAME}-mapr-kdc mapr-webproxy mapr-core-repo mapr-mep-repo ${auxClusterImageArr[@]} ${auxGlobalImageArr[@]}; do
  for auxContainer in $auxContainerList ; do
    ip=""	# Set this value ONLY if container is already running on cluster network and has an IP address.  Otherwise, let add_host generate an ip.

    # If there is a : in the auxContainer name, it is a docker image with a TAG.  Set auxContainer for name without TAG
    if [[ $auxContainer =~ ":" ]]; then
      auxContainer=${auxContainer%:*}
    fi
    auxContainerDash="${auxContainer//./-}" # Replace periods with hyphens. Used for hostname to ensure proper domain setting.
    auxContainerDash="${auxContainerDash//_/-}" # Replace underscore with hyphens. Used for hostname to ensure valid hostname setting.
    if [[ ! -z $DOMAIN ]] ; then 
      auxHostName=${auxContainerDash}.$DOMAIN
    else 
      auxHostName=$auxContainerDash
    fi

    # If auxContainerDash has ip address, use it
    # But if it isn't on the container network remove the container so it will be created on the network (1 network version of this script)
    if docker_container_exists $auxContainerDash; then
      # TBD: If the mapr-webproxy container exists, it will need to be restarted with the new cluster's IPs added to its hostlist.  But a
      #      removed cluster needs to have its entries removed from the web-proxy hosts.  For now, always create a new webproxy...just one
      #      cluster at a time.
      [[ $auxContainerDash = mapr-webproxy ]] && docker rm -vf $auxContainerDash
      if ! docker_container_on_network $auxContainerDash $clusterNetwork; then
        docker rm -vf $auxContainerDash
      else
        ip=$(docker inspect --format "{{ .NetworkSettings.Networks.$clusterNetwork.IPAddress }}" $auxContainerDash)
      fi
    fi
    add_host $auxHostName $ip
  done
  INDENT=${INDENT%  }
}

start_aux_containers()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2

  # TBD:  Put auxClusterImageArr containers in Cluster Network
  # TBD:  Put auxGlobalImageArr containers in auxGlobalImageArr Network. Also be sure to include this as a network for all cluster nodes
  # webproxy and repos can be shared by multiple clusters.  For now, mysql and kdc are per cluster.
  #for auxContainer in ${CLUSTERNAME}-mapr-mysql ${CLUSTERNAME}-mapr-kdc mapr-webproxy mapr-core-repo mapr-mep-repo ${auxClusterImageArr[@]%:*} ${auxGlobalImageArr[@]%:*}; do
  # 
  #for auxContainer in ${CLUSTERNAME}-mapr-mysql ${CLUSTERNAME}-mapr-kdc mapr-webproxy mapr-core-repo mapr-mep-repo ${auxClusterImageArr[@]} ${auxGlobalImageArr[@]}; do
  for auxContainer in $auxContainerList ; do
    # If there is a : in the auxContainer name, it is a docker image with a TAG.  Save that as the Image to start and set auxContainer for name without TAG
    if [[ $auxContainer =~ ":" ]]; then
      auxImage=$auxContainer
      auxContainer=${auxImage%:*}
    fi
    auxContainerDash="${auxContainer//./-}" # Replace periods with hyphens. Used for hostname to ensure proper domain setting.
    auxContainerDash="${auxContainerDash//_/-}" # Replace underscore with hyphens. Used for hostname to ensure valid hostname setting.

    # MapR core repo always uses port 8080 and mep repo always uses port 8081 regardless of version
    # remove existing repo of differing version if necessary to avoid port conflict
    # TBD:  Just put these images in the auxGlobalImageArr and remove this if clause
    VERS=""
    if [[ $auxContainerDash = mapr-core-repo ]] || [[ $auxContainerDash = mapr-mep-repo ]] ; then
      [[ $auxContainerDash = mapr-core-repo ]] && VERS=$MAPR_CORE_VER
      [[ $auxContainerDash = mapr-mep-repo ]] && VERS=$MAPR_MEP_VER
      # If the MapR Core or MEP repo is running but is the wrong version, remove it.
      # A new repo container with the correct version will get started below
      if docker_container_exists $auxContainerDash; then
        if [[ $(docker inspect --format '{{ .Config.Image }}' $auxContainerDash 2>/dev/null | cut -f 2 -d ':') != "$VERS" ]]; then
          docker rm -vf $auxContainerDash
        fi
      fi
    fi

    # Also remove Auxiliary Global containers with incorrect version running 
    for nextImage in ${auxGlobalImageArr[@]}; do
      VERS=${nextImage#*:}
      if [[ ${nextImage%:*} = $auxContainer ]]; then
        if docker_container_exists $auxContainerDash; then
          if [[ $(docker inspect --format '{{ .Config.Image }}' $auxContainerDash 2>/dev/null | cut -f 2 -d ':') != "$VERS" ]]; then
            docker rm -vf $auxContainerDash
          fi
        fi
        break 
      fi
    done
    
    if docker_container_exists $auxContainerDash; then
      if ! docker_container_running $auxContainerDash; then
        docker start $auxContainerDash
      fi
      if docker_have_info $auxContainerDash; then
        continue;
      else
        docker_set_info $auxContainerDash
      fi
    else
      if [[ ! -z $DOMAIN ]] ; then 
        auxHostName=${auxContainerDash}.$DOMAIN
      else 
        auxHostName=$auxContainerDash
      fi

      case $auxContainerDash in
        ${clusterNameDash}-mapr-mysql)
	  if mysql_required; then
            IMAGE_ENV+=(MYSQL_ROOT_PASSWORD=mapr)
            start_container $MYSQL_IMG -h $auxHostName --name=$auxContainerDash 
            echo "docker rm -vf $auxContainerDash & " >> /tmp/remove_cluster_${CLUSTERNAME}.sh
	  fi
          ;;
        mapr-webproxy)
          squidPort=3128
          while portinuse $squidPort ; do
            let squidPort++
          done
          start_container $PROXY_IMG -h $auxHostName --name=$auxContainerDash -p $squidPort:3128
          PROXY_MSG="Set browser proxy to $(hostname -f):$squidPort"
          ;;
        ${clusterNameDash}-mapr-kdc)
          if $KERB; then
            startClusterOpts+=" -k $auxHostName -K $KERB_REALM"
            start_container $KDC_IMG  -h $auxHostName --name=$auxContainerDash 
            echo "docker rm -vf $auxContainerDash & " >> /tmp/remove_cluster_${CLUSTERNAME}.sh
  	  fi
  	  ;;
        mapr-core-repo)
          start_container $CORE_REPO_IMG -h $auxHostName --name=$auxContainerDash # -P -p 8080:80
  	  ;;
        mapr-mep-repo)
          start_container $MEP_REPO_IMG -h $auxHostName --name=$auxContainerDash # -P -p 8081:80
  	  ;;
        *)
          start_container $auxImage -h $auxHostName --name=$auxContainerDash 
  	  ;;
      esac
    fi
  done
  INDENT=${INDENT%  }
}

create_cluster_network()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  clusterNetwork=${CLUSTERNAME}_nw
  if ! docker_network_exists $clusterNetwork;  then
    docker_network_create $clusterNetwork
  fi
  INDENT=${INDENT%  }
}

# Set docker network to 172.24.0.0/16 unless host is 172.24, then increment to 172.25
octet2=24
while [[ "$(hostname -i)" =~ 172.$octet2 ]] ; do let octet2+=1; done
dockerNetworkSubnet="172.$octet2.0.0/16"
dockerNetworkGateway="172.$octet2.0.1"

create_mapr_network()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  if docker_network_exists mapr_nw; then
    maprSubnet=$(docker network inspect mapr_nw | jq -r '.[].IPAM.Config|.[].Subnet')
    if [[ $dockerNetworkSubnet != $maprSubnet ]]; then
      docker network rm mapr_nw || errexit "Cannot remove existing docker network mapr_nw which conflicts with host network"
    fi
  fi
  if ! docker_network_exists mapr_nw;  then
    docker network create --subnet $dockerNetworkSubnet mapr_nw --gateway $dockerNetworkGateway
  fi
  INDENT=${INDENT%  }
}

# Put existing clusters in hosts file.  Necessary for web-proxy container.  TBD: check for dup entries!
setup_existing_addhost_args()
{
  local nextCluster
  for nextCluster in ${clusterArr[@]}; do
  addHostList=$(docker inspect --format '{{ .HostConfig.ExtraHosts }}' ${nextCluster}-s1  | sed -e 's/\[//' -e 's/\]//')
    while [[ $addHostList =~ ":" ]]; do
      nextHost=${addHostList%%:*}
      addHostList=${addHostList#*:}
      nextIP=${addHostList%% *}
      addHostList=${addHostList#* }
      #addHostString="$addHostString --add-host '$nextHost:$nextIP'"
      dockerProxyAddHostArgsArr+=( --add-host "$nextHost":$nextIP )
    done
  done
}

setup_new_addhost_args()
{
  INDENT="$INDENT  "
  $VERBOSE && echo "$(date): ${INDENT}$FUNCNAME $@" 1>&2
  local nextHost
  local HN
  local IP
  # loop through ipAddrArr and gen --add-host params
  # remember to add addhost string to docker args for all startups
  for nextHost in ${ipAddrArr[@]}; do

    HN=${nextHost%:*}
    IP=${nextHost##*:}
    #If hostName is fqdn, fix to include short name "--add-host 'mapr01 mapr01.mapr.local':172.200.0.5"
    if [[ $HN =~ "." ]] ; then 
      HN="$HN ${HN%%.*}"
    fi
    dockerAddHostArgsArr+=( --add-host "$HN":$IP )

  done
  INDENT=${INDENT%  }
}

#### MAIN ####
create_mapr_network
#find_containers mapr_nw 
setup_aux_ips
#echo ${ipAddrArr[@]}
setup_mapr_ips
#echo ${ipAddrArr[@]}

setup_existing_addhost_args
setup_new_addhost_args

start_aux_containers

NODESTOBELAUNCHED=$NUMBEROFNODES
# Use service_list.txt [0] is for additional nodes
# [1] through #[@] ALWAYS get launched and supercede NUMBEROFNODES
# read
i=1
DRILLPORTMAP=""
DRILLPORT=31010
while [[ $i -le $NODESTOBELAUNCHED ]]; do
  if [[ $MAPR_SERVER_IMG =~ "drill" ]] ; then
    while portinuse $DRILLPORT ; do
      let DRILLPORT++
    done
    DRILLPORTMAP="-p $DRILLPORT:31010"
  fi
  start_container $MAPR_SERVER_IMG:$MAPR_SERVER_TAG --name=${clusterNameDash}-s$i --privileged -P $DRILLPORTMAP --memory=${MEMTOTAL}k
  let i++
done

NODESTOBELAUNCHED=$NUMBEROFCLIENTS
# Use service_list.txt [0] is for additional nodes
# [1] through #[@] ALWAYS get launched and supercede NUMBEROFNODES
# read
i=1
while [[ $i -le $NODESTOBELAUNCHED ]]; do
    start_container $MAPR_CLIENT_IMG:$MAPR_CLIENT_TAG --name=${clusterNameDash}-c$i --privileged -P --memory=${MEMCLIENT}k
    let i++
done
SSHPORT=2222
while portinuse $SSHPORT ; do
  let SSHPORT++
done

# TBD:  Don't bother with 2222+.  Let port get assigned and just use ./cluster.sh -a connect to find port
#       That way, we don't get a conflict from a stopped cluster.  On restart, stopped container will fail b/c cannot map port
start_container $MAPR_LAUNCHER --name=${clusterNameDash}-c${i}-launcher --privileged -P -p "$SSHPORT:22" --memory=${MEMCLIENT}k
launcherContainer=$containerId
create_hosts_file
create_clush_groups_file
docker cp $CLUSHGRPSFILE $launcherContainer:/home/mapr/groups
docker cp $HOSTSFILE $launcherContainer:/home/mapr/hosts
for nextFileOrDir in ${fileArr[@]}; do
  # if a local directory is specified, copy all files and subdirectories in it to /home/mapr in launcher container
  # (docker cp of a local directory with a trailing /. copies all files in the directory)
  # use -L to copy file rather than symlink.  Symlinks should be created in start-cluster-custom.sh script.
  [[ -d $nextFileOrDir ]] && nextFileOrDir=${nextFileOrDir}/.
  docker cp -L $nextFileOrDir $launcherContainer:/home/mapr
done

# Invoke custom launcher script launch-cluster-custom.sh
# Get script directory (absolute or relative) to source launch-cluster-custom.sh
scriptDir=$(dirname $BASH_SOURCE)
[[ ! $scriptDir =~ ^/ ]] && scriptDir=$(pwd)/$scriptDir

[[ -f $scriptDir/launch-cluster-custom.sh ]] && . $scriptDir/launch-cluster-custom.sh

# Restart docker to address "Too many open files" issue when > ~18 containers
if [[ $(docker ps -q | wc -l) -gt 18 ]]; then
  echo 'Stopping docker to address "Too many open files" issue.'
  #sleep 15
  systemctl stop docker
  systemctl stop docker

  echo Starting docker 
  #sleep 15
  systemctl start docker

  echo Wait 60 seconds for container daemons to start
  sleep 60
fi

# Run the start-cluster script on the launcher node

if [[ -f /sys/hypervisor/uuid ]] && [[ "$(head -c 3 /sys/hypervisor/uuid)" = "ec2" ]]; then
  # Running in AWS
  publicHostname=$(curl http://169.254.169.254/latest/meta-data/public-hostname 2>/dev/null)
elif [[ -d /var/lib/waagent ]]; then # This is the directory for the Windows Azure agent
  # Running in Azure
  publicHostname=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2017-08-01&format=json"  2>/dev/null \
                   | jq -r .network.interface[].ipv4.ipAddress[].publicIpAddress )
fi

[[ -z $publicHostname ]] && publicHostname='Not Found'
echo $publicHostname | grep 'Not Found' > /dev/null && publicHostname=$(hostname -f)
startClusterOpts+=" -H $publicHostname"

clusterStartCmd="docker exec $dockerExecOpts $launcherContainer bash -c '/home/mapr/start-cluster.sh $startClusterOpts 2>/home/mapr/start-cluster.err | tee /home/mapr/start-cluster.out'"
$VERBOSE && echo "$clusterStartCmd"

if [[ ! -z $AWS_CFT_DOCKER_URL ]] ; then
  echo -n '{"Status" : "SUCCESS", "Reason" : "Launched docker containers", "UniqueId" : "Launching script", "Data" : "' > /tmp/awsDockerURL.json
  echo -n "start-cluster.sh $startClusterOpts" >> /tmp/awsDockerURL.json
  echo '" }' >> /tmp/awsDockerURL.json
  curl -T /tmp/awsDockerURL.json "$AWS_CFT_DOCKER_URL"
fi

#$clusterStartCmd
docker exec $dockerExecOpts $launcherContainer bash -c "/home/mapr/start-cluster.sh $startClusterOpts 2>/home/mapr/start-cluster.err | tee /home/mapr/start-cluster.out"

#rm -f /tmp/remove_aux_containers.sh
#touch /tmp/remove_aux_containers.sh
#chmod +x /tmp/remove_aux_containers.sh
#for auxContainerId in $(list_aux_container_ids) ; do
  #echo "docker rm -vf $auxContainerId &" >> /tmp/remove_aux_containers.sh
#done

echo ""
echo "Access Launcher Node:"
echo "    sshpass -p "mapr" ssh -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p $SSHPORT root@$(hostname -f)"
echo "Monitor cluster start up on edge node:"
echo "    sshpass -p "mapr" ssh -o LogLevel=quiet -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p $SSHPORT root@$(hostname -f) tail -f /home/mapr/start-cluster.out"
# echo "Remove created containers (and volumes):"
# echo "    /tmp/remove_cluster_${CLUSTERNAME}.sh"
# [[ ! -z $DOCKER_VOLUME ]] && echo "If removing containers manually, use 'docker rm -v' to ensure docker volumes are removed"
cleanup

