current version of AIX is not supporting procstack.
in case the procstack is initiated by the process it can get hung and cause service degradation.
replacing original procstack with a shell script which will capture the dbx output for the RCS process.
replace the original procstack in the same location with name "procstack_backUp_dbx"
this is a WA to be used only for RCS process. No stack collection possible for any other process. 
for RCS <PrintProcssStack>0</PrintProcssStack> need to 1 in ureCfg.xml and RCS restart is required to enable
