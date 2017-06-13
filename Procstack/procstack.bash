#!/usr/bin/ksh
##############################################################################################################
# replacing original procstack with a shell script which will capture the dbx output for the RCS process.
# replace the original procstack in the same location with name "procstack_backUp_dbx"
# this is a WA to be used only for RCS process. No stack collection possible for any other process. 
# for RCS <PrintProcssStack>0</PrintProcssStack> need to 1 in ureCfg.xml and RCS restart is required to enable
#     *****to enable only when its required.
#
# usage : procstack <PID>
#
# V 0.5
#
# 0.3 = added timeout_monitor for dbx collection (removed)
# 0.4 = added prepare_alarm_and_send module to intimate alarm in case of hung
# 0.5 = revised timeout_monitor to timeout function
#
# Contact : *KC1 Shared Services Support BE <KC1SharedServicesSupportBE@int.amdocs.com>
##############################################################################################################


prepare_alarm_and_send()
{
# 0.4 modification
####--------------------------------
# this module can send alarm to mshell
# import JBOSS_HOME if using user other than root
# first argument is the EVENT starting with ALERT_MON only
# second argument is the severity 1=critical 2=major 3=minor 4=warning 5=clear
# third is detailed message "without" space Eg:HungProcessDetected
# 	Usage : prepare_alarm_and_send ALERT_MON_DBX_HUNG 1 HungProcessDetected
####--------------------------------

EventId=$1
EventSeverity=$2
EventMessage=$3

EventNodeType=`grep -i "node.type" $JBOSS_HOME/conf/wrapper.conf|awk -F"=" '{print $3}'`
EventIP=`grep -w  \`hostname\` /etc/hosts|awk '{print $1}' |head -1`
EventHost=`hostname`
if [ -z $EventIP ];then
 EventIP=$EventHost
fi
EventTime=`date '+%H%M%S%d%m%Y'`
EventLegacyApp=LEGACY_${EventNodeType}_APP
EventProc=\"\"
EventEntity=\"\"


$JBOSS_HOME/bin/sendXMLAlarm.pl $EventId $EventSeverity $EventLegacyApp $EventMessage \"$EventNodeType\" \"$EventIP\" \"$EventHost\" $EventProc $EventEntity \"$EventTime\"
}




GetStack()
{
#---function within a function---
#-- 0.5 modification
timeout() {

    time=$1

    # start the command in a subshell 
    # (spawn accepts one command)
	# usage : timeout <time> <command>
	# returns 0=No timeout, 1=successful timeout , 2=hung though timedout
    command="/bin/sh -c \"$2\"" 

    expect -c "set echo \"-noecho\"; set timeout $time; spawn -noecho $command; expect timeout { exit 1 } eof { exit 0 }"    

    if [ $? = 1 ] ; then
        echo "PStack: Timeout after ${time} seconds"
# initializing ret value to 1 as timeout is initiated
		ret=1
        if [[ `ps -fe | grep "dbx" | grep ${RCS_PID} |grep -v grep|wc -l` -eq 0 ]]; then
            echo "PStack: No process left over, clean exit"
            export ret=1
        else
            echo "PStack: hung process found"
            export ret=2
        fi
#		echo $ret
		return $ret
    fi
	


}


#---function within a function ends


#--------------------------------------------------
#prepare the initial thread info collect statement
#--------------------------------------------------
echo "Pstack: Preparing thread `date`" > ${TEMP_PATH}/threaddbx_${RCS_PID}.txt 2>/dev/null
cat > ${TEMP_PATH}/preparedbx_${RCS_PID}.txt <<EOF
thread
detach
EOF

#--------------------------------
#collect the thread numbers
#--------------------------------
timeout $TimeOutSeconds "dbx -a $RCS_PID -c ${TEMP_PATH}/preparedbx_${RCS_PID}.txt >> ${TEMP_PATH}/threaddbx_${RCS_PID}.txt 2>/dev/null"
exitcode=$?
    if [[ $exitcode == 0 ]]; then
        prepare_alarm_and_send ALERT_MON_DBX_HUNG 5 NoProcessHung
    elif [[ $exitcode == 1 ]]; then
        exit 1;
    elif [[ $exitcode == 2 ]]; then
        prepare_alarm_and_send ALERT_MON_DBX_HUNG 1 HungProcessDetected
        exit 1;
    fi

#-----------------------------------------------
#prepare the above collected threadnumber 
#to extract thread stack for respective threadId
#-----------------------------------------------

for t_num in `cat ${TEMP_PATH}/threaddbx_${RCS_PID}.txt|grep -E 't[0-9]+ '|awk '{print $1}'|sed 's/>//g'|sed 's/[^0-9]*//g'|sort -n`
do echo "sh echo \"....................................\""
echo "sh echo \"t$t_num stack details\""
echo "sh date"
echo "sh echo \"....................................\""
echo "thread current $t_num"
echo "where"
done > ${TEMP_PATH}/threaddump_${RCS_PID}.txt
echo "detach" >> ${TEMP_PATH}/threaddump_${RCS_PID}.txt

#-----------------------------------------
#collect the stack for respective threads
#-----------------------------------------
echo "******** PRINTING DBX FOR PROCESS : PID=${RCS_PID} *****" >${FINAL_LOG}
ps -ef|grep ${RCS_PID}|grep -vE "grep|procstack" >>${FINAL_LOG}
cat ${TEMP_PATH}/threaddbx_${RCS_PID}.txt >>${FINAL_LOG}
echo >> ${FINAL_LOG}
echo "====================================" >> ${FINAL_LOG}
echo >> ${FINAL_LOG}

timeout $TimeOutSeconds "dbx -a $RCS_PID -c ${TEMP_PATH}/threaddump_${RCS_PID}.txt >> ${FINAL_LOG} 2>/dev/null"
exitcode=$?
    if [[ $exitcode == 0 ]]; then
        prepare_alarm_and_send ALERT_MON_DBX_HUNG 5 NoProcessHung
    elif [[ $exitcode == 1 ]]; then
        exit 1;
    elif [[ $exitcode == 2 ]]; then
        prepare_alarm_and_send ALERT_MON_DBX_HUNG 1 HungProcessDetected
        exit 1;
    fi

echo "***End of Log***" >> ${FINAL_LOG}


#--------------------------------
#remove temp files
#--------------------------------
rm -f ${TEMP_PATH}/preparedbx_${RCS_PID}.txt ${TEMP_PATH}/threaddbx_${RCS_PID}.txt ${TEMP_PATH}/threaddump_${RCS_PID}.txt

return 0
}


#============MAIN STARTS HERE==============                                                                
#--------------------------------
#get the pid of the RCS/process $1
#--------------------------------
BASE_PATH=/staging/billing/data/log
TEMP_PATH=/tmp
TimeOutSeconds=200
RCS_PID=$1
process_name=`ps -ef|grep -i rcs|grep -ivE "grep|procstack" |grep $RCS_PID|tail -1|awk '{for (I=1;I<=NF;I++) if ($I == "-rcsname") {print $(I+1)};}'` 2>/dev/null
FINAL_LOG=${BASE_PATH}/${process_name}_DBX_${RCS_PID}_`date +"%Y%m%d%H%M%S"`.log

#--------------------------------
# When below condition is met, it exits
# 1. if PID is null
# 2. if process_name is null, it assumes this pid is not for RCS
# 3. if this pid already has dbx collectiong
#--------------------------------

    if [[ $RCS_PID == "" ]]; then
        echo "PStack: No PID"
        exit;
    elif [[ $process_name == "" ]]; then
        echo "PStack: PID=$1 is not among RCS process, stack collection is not possible for any other process, exiting.."
        exit;
    elif [[ `ps -ef|grep "dbx"|grep -v grep |wc -l` -gt 0 ]]; then
        echo "PStack: Found DBX process already running, exiting.."
        exit;
    fi

#--------------------------------
# checks if the process for RCS_PID is running then collect stack
# else exit..
#--------------------------------

    if [[ `ps -ef|grep $RCS_PID |grep rcsname |grep -ivE "grep|procstack"  |wc -l` -gt 0 ]]; then
        GetStack $RCS_PID
        if [[ $? -eq 0 ]]; then 
           echo "PStack: Stack collection completed"
           echo "PStack: check ${FINAL_LOG}"
        else
           echo "PStack: Stack collection failed"
        fi
    else
        echo "PStack: Process having PID=$RCS_PID does not exist"
        exit;
    fi


