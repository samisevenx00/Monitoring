<#
    NAME: Monitoring_center.ps1
    AUTHOR: HOCINI Sami
    LASTEDIT: 19/12/2019 09:41:00
   .Link
 #Requires -Version 4.0
 #>

 ###############################################################################################################
 ## Chargement des modules
 ##############################################################################################################

 If ( ! (Get-module Influx )) {
    Import-Module Influx
}

 ###############################################################################################################
 ## Chargement des Variables
 ##############################################################################################################

$hostname = (Get-ADDomainController).domain


# login et Mot de passe a crypter !!!
# Variables a Modifier
####################################################################
$username = "telegraf"
$password = ConvertTo-SecureString "" -AsPlainText -Force 
$psCred = New-Object System.Management.Automation.PSCredential -ArgumentList ($username, $password)
$InfluxdbSRV = ""
$SearchBASE_OU = ""
$serverAD = ""
$LogPath = ""
######################################################################

$date = Get-Date
$DaysInactive = 90  
$time = (Get-Date).Adddays(-($DaysInactive))
$ADUserList = Get-ADUser -Filter * -SearchBase $SearchBASE_OU `
             -Properties "Displayname","passwordlastset", "passwordneverexpires", "LastLogonTimeStamp", "LastLogonDate" -Server $serverAD
$ADComputers = Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion, LastLogonDate, Enabled, LastLogonTimeStamp


###############################################################################################################
## Chargement des Fonctions
##############################################################################################################

Function _Get_LastuserPasswordSet {
     param (
         [datetime]
         $date,
         $UserList
     )
     
     $date = $date.AddMinutes(-10)
     $Pwd_Users = $UserList | Where-Object {$_.Enabled -eq "True" -and $_.passwordlastset -gt $date}
     
     foreach($Pwd_User in $Pwd_Users){

        $PwdResetTime = $Pwd_user.passwordlastset
        $PwdResetTime = ([DateTimeOffset] $PwdResetTime).ToUnixTimeMilliseconds()
        $Pwd_Username = $Pwd_user.DisplayName
        $Pwd_Username = $Pwd_Username -replace '\s','-'
        
        if($Pwd_Username -ne 0){
            
            Write-Influx -Measure "ad_account"`
                -Tags @{Domain="$hostname"; ad_value="User_LastPasswordSet"} -Metrics @{username="$Pwd_Username"}`
                -Database telegraf -Server $InfluxdbSRV -Credential $psCred

        }elseif($Pwd_Username -eq 0){
        
            Write-Influx -Measure "ad_account"`
                -Tags @{Domain="$hostname"; ad_value="User_LastPasswordSet"} -Metrics @{username="NoUserFound"}`
                -Database telegraf -Server $InfluxdbSRV -Credential $psCred
        
       }        
     }    
 }

Function _Get_ADAccountStat {
    param (
        $UserList,
        $hostname
    )

    $ADAccountDisabled = ($UserList | Where-Object { $_.Enabled -eq "False"}).Count
    Write-Influx -Measure "ad_account"`
         -Tags @{Domain="$hostname"; ad_value="ADAccountDisabled"} -Metrics @{count=[int]$ADAccountDisabled}`
         -Database telegraf -Server $InfluxdbSRV -Credential $psCred
    
    $ADCountpasswordExpired = (Search-ADAccount -PasswordExpired).count
    Write-Influx -Measure "ad_account"`
        -Tags @{Domain="$hostname"; ad_value="ADAccountPwdExpired"} -Metrics @{count=[int]$ADCountpasswordExpired} `
        -Database telegraf -Server $InfluxdbSRV -Credential $psCred
    
    $pwdNeverExp = ($UserList | where-object {$_.passwordneverexpires -eq "True"}).count
    Write-Influx -Measure "ad_account"`
        -Tags @{Domain="$hostname"; ad_value="AdpwdNeverExp"} -Metrics @{count=[int]$pwdNeverExp}`
        -Database telegraf -Server $InfluxdbSRV -Credential $psCred

 }

Function _Get_Admins {
    Param(
        [ValidateSet("Admins du domaine", "Administrateurs de l'entreprise")]
        [String]
        $Name 
        )

    if($Name -eq "Admins du domaine"){

        $Measure = "Domain_Admin"

    }else{
    
        $Measure = "Entreprise_Admin"
    }

    $ADGroupMembers = Get-ADGroupMember -Identity $Name 

    $ADGroupmembersCount = $ADGroupMembers.Count
    Write-Influx -Measure "$Measure" `
            -Tags @{Domain="$hostname"} -Metrics @{count=[int]$ADGroupmembersCount} `
            -Database telegraf -Server $InfluxdbSRV -Credential $psCred

    foreach($member in $ADGroupMembers){

        ### Liste des Domain Admins         
        $memberName = $member.name -replace '\s','-'       
        Write-Influx -Measure "$Measure"`
                -Tags @{Domain="$hostname"} -Metrics @{user="$memberName"}`
                -Database telegraf -Server $InfluxdbSRV -Credential $psCred

        }
}

Function _Get_LockedAccount {
    
    $lockedAccounts = @()
    $lockedAccounts = Search-ADAccount -LockedOut | Select-Object Name, LastlogonDate, Enabled
    $lockedAccountscount = ($lockedAccounts | Measure-Object).Count

    Write-Influx -Measure "LockedAccount_count"`
            -Tags @{Domain="$hostname"} -Metrics @{Lockeduser=[int]$lockedAccountscount}`
            -Database telegraf -Server $InfluxdbSRV -Credential $psCred

    if($lockedAccountscount -ne 0){

        foreach($lockedAccount in $lockedAccounts){

            $LockedUser = $lockedAccount.name
            Write-Influx -Measure "LockedAccount"`
                    -Tags @{Domain="$hostname"} -Metrics @{Lockeduser=$LockedUser}`
                    -Database telegraf -Server $InfluxdbSRV -Credential $psCred   
        }
    }else{
        
        $LockedUser = "NoLockedUserFound" 
        Write-Influx -Measure "LockedAccount"`
            -Tags @{Domain="$hostname"} -Metrics @{Lockeduser=$LockedUser}`
            -Database telegraf -Server $InfluxdbSRV -Credential $psCred        
    }
}

Function _Get_DHCPStats {
    param (
        $dhcp
    )
    
    $DhcpScope = Get-DhcpServerv4ScopeStatistics -ComputerName $dhcp

    foreach($Scope in $DhcpScope){

        $ScopeState = (Get-DhcpServerv4Scope -ComputerName $dhcp -ScopeId $Scope.scopeId).State
        
        if($ScopeState -eq "active"){

        $ScopeID = $Scope.ScopeId
        $ScopeFree = $Scope.Free
        $ScopeInUse = $Scope.InUse
        $ScopePecentageInUse = $Scope.PercentageInUse
        $ScopeReserved = $Scope.Reserved
        $ScopeDescription = (Get-DhcpServerv4Scope -ComputerName $dhcp -ScopeId $ScopeID).Description
        

        Write-Influx -Measure "dhcp_mon"`
                -Tags @{Domain="$hostname"; dhcp=$dhcp; dhcp_value="dhcp_stat"} `
                -Metrics @{ScopeId=$ScopeID; Free=$ScopeFree; InUse=$ScopeInUse; PercentageInUse=$ScopePecentageInUse; Reserved=$ScopeReserved; Description= $ScopeDescription; State=$ScopeState}`
                -Database telegraf -Server $InfluxdbSRV -Credential $psCred
    
        }
    }
}

Function _Get_CompUsers {
    
    $Windowsxp = ($ADComputers | Where-Object {$_.OperatingSystem -match "Windows XP" -and $_.Enabled -eq "True"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{Windowsxp="$Windowsxp"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred 

    $Windows10 = ($ADComputers | Where-Object {$_.OperatingSystem -match "Windows 10" -and $_.Enabled -eq "True"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{Windows10="$Windows10"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred 

    $Windows7 = ($ADComputers | Where-Object {$_.OperatingSystem -match "Windows 7" -and $_.Enabled -eq "True"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{Windows7="$Windows7"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred

    $Server2008 = ($ADComputers | Where-Object {$_.OperatingSystem -match "Windows Server 2008" -and $_.Enabled -eq "True"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{Server2008="$Server2008"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred
         
    $Server2012 = ($ADComputers | Where-Object {$_.OperatingSystem -match "Windows Server 2012" -and $_.Enabled -eq "True"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{Server2012="$Server2012"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred

    $Server2016 = ($ADComputers | Where-Object {$_.OperatingSystem -match "Windows Server 2016" -and $_.Enabled -eq "True"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{Server2016="$Server2016"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred

    $MacOs = ($ADComputers | Where-Object {$_.OperatingSystem -match "Mac" -and $_.Enabled -eq "True"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{MacOs="$MacOs"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred

    $Disabled = ($ADComputers | Where-Object {$_.Enabled -eq "False"}).count

    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{Disabled_Computers="$Disabled"}`
        -Database telegraf -Server $influxdbSRV -Credential $psCred


}

Function _Get_InactivesCompUsers90 {

    $Computers_90d = $ADComputers | Where-Object {$_.Enabled -eq "True" -and $_.LastLogondate -lt $time}
    $Computers_90dcount = $Computers_90d.count
    Write-Influx -Measure "ad_Computers"`
        -Tags @{Domain="$hostname"; ad_value="Computer_version"} -Metrics @{day90_computers="$Computers_90dcount"}`
        -Database telegraf -Server $InfluxdbSRV -Credential $psCred

    $users_90d = $ADUserList | Where-Object {$_.Enabled -eq "True" -and $_.LastLogondate -lt $time}
    $users_90dcount = $users_90d.count
    Write-Influx -Measure "ad_users"`
        -Tags @{Domain="$hostname"; ad_value="users_90d"} -Metrics @{day90_users="$users_90dcount"}`
        -Database telegraf -Server $InfluxdbSRV -Credential $psCred
}


###############################################################################################################
## Lancement des Fonctions
##############################################################################################################
[int]$startMs = (Get-Date).Second

_Get_LastuserPasswordSet -date $date -UserList $ADUserList  
_Get_ADAccountStat -UserList $ADUserList -hostname $hostname
_Get_LockedAccount
_Get_DHCPStats -dhcp 10.14.1.20
_Get_Admins -Name 'Administrateurs de l''entreprise'
_Get_Admins -Name 'Admins du domaine'
_Get_CompUsers
_Get_InactivesCompUsers90

[int]$endMs = (Get-Date).Second
Write-Host $($endMs - $startMs)