<#

    .SYNOPSIS
    RTI Scheduler Attendance for Arkansas Public Schools
    Author: Craig Millsap, CAMTech Computer Service, LLC.

    .DESCRIPTION
    This will pull from Cognos and upload attendance to RTI Scheduler.

    By default this script will run in verifcation mode. You must invoke via
    .\RTIScheduler_Upload_ATT_to_eSchool.ps1 -RunMode R

    #1. YOU MUST MAKE SURE YOUR PERIOD/HOUR MATCHES BETWEEN ESCHOOL AND RTI SCHEDULER.
        Otherwise you'll end up submitting an absence for the wrong period.

    #2. Pretty sure this should only be run once a day. Well in advance of your attendance
        clerk reviewing attendance.

    #3. You need to set a default period for RTI Scheduler in the Sync Settings.

#>

Param(
    [Parameter(Mandatory=$false)]$RunMode = 'V' #R for Run, V for Verification.
)

$currentPath=(Split-Path ((Get-Variable MyInvocation -Scope 0).Value).MyCommand.Path)

if (!(Test-Path $currentPath\settings.ps1)) {
    Write-Host "Error: settings.ps1 file not found. Please use the settings-sample.ps1 as an example."
    exit(1)
}

. $currentPath\settings.ps1

if ((Test-Path $currentPath\attendance_overrides.ps1)) {
    . $currentPath\attendance_overrides.ps1
}

if ([int](Get-Date -Format MM) -ge 7) {
    $schoolyear = [int](Get-Date -Format yyyy) + 1
} else {
    $schoolyear = [int](Get-Date -Format yyyy)
}

try {
    if ((Get-Date "$($attendanceUntilDate)").Year -ne $schoolyear) {
        Throw        
    }
} catch {
    Write-Error "The `$attendanceUntilDate must be in the current school year." -ErrorAction Stop
    exit 1
}

try {

    Connect-ToCognos

    if (Test-Path "$currentPath\schools.csv") {
        #if you need to override anything out of Cognos you can use the same format as Clever schools.csv
        $eschool_buildings = Import-CSV -Path "$currentPath\schools.csv" | Select-Object School_id,School_name
    } else {
        $eschool_buildings = Get-CogSchool | Select-Object School_id,School_name
    }
    
} catch {
    Write-Error "Failed to connect to Cognos."
    exit 1
}

if ($islinux) { $OFS = "`r`n" }
$RTIAttendance = '' #string to to hold the CSV (without headers) to upload to eSchool.

$eschool_buildings | ForEach-Object {

    if ($rti_building_numbers.Keys -notcontains "$($PSItem.School_name)") {
        #building not specified in the $rti_building_numbers
        return
    }

    $rti_building_number = $rti_building_numbers.$($PSItem.School_name)
    $eschool_building_number = $PSItem.School_id

    if ($uploadAttendance) {
        $RTIBuildingAttendanceFromRTI = Invoke-RestMethod `
            -Uri "https://rtischeduler.com/data-export-api/schools/$($rti_building_number)/attendance?date=$(Get-Date -Format "yyyy-MM-dd")&absencesOnly=true" `
            -Headers @{ "rti-api-token" = "$($RTIToken)" }
        

        if ($RTIBuildingAttendanceFromRTI) {
            $RTIBuildingAttendance = $RTIBuildingAttendanceFromRTI |
            ForEach-Object {

                #if absenceCode is set in the settings.ps1 then we will use it when we get an A from RTI Scheduler. If it doesn't match A then we will use the value from RTI Scheduler. IE. T for tardy.
                $attendanceCode = $absenceCode ? ($PSItem.attendanceCode -eq 'A' ? $absenceCode : $PSItem.attendanceCode) : $PSItem.attendanceCode

                [PSCustomObject]@{
                    "STUDENT_ID" = $PSItem.studentId
                    "BUILDING" = $eschool_building_number
                    "ATTENDANCE_CODE" = $attendanceCode
                    "ATTENDANCE_DATE" = (Get-Date "$($PSitem.scheduleDate)").ToShortDateString()
                    "ATTENDANCE_PERIOD" = $PSitem.Period
                    "ATT_COMMENT" = "RTIScheduler"
                    "SCHOOL_YEAR" = $schoolyear
                    "SOURCE" = 'O' #Office
                    "SEQUENCE_NUM" = 1
                    "SUMMER_SCHOOL" = 'N'
                    "MINUTES_ABSENT" = ($uploadAttendanceMinutes ? $uploadAttendanceMinutes : 11) #This is a guess. We have no way of knowing how long a period is in eSchool. 11 minutes should get us past the minimum required to be counted as absent.
                    "ENTRY_DATE_TIME" = $PSitem.scheduleDate
                    "ENTRY_USER" = $CognosUsername
                    "ENTRY_ORDER_NUM" = 1
                    "BOTTOMLINE" = 'Y'
                }
            }
        }

        if ($RTIBuildingAttendance) {
            #Append without headers. Uploads to eSchool do not have headers.
            $RTIAttendance += $RTIBuildingAttendance | ConvertTo-Csv -UseQuotes AsNeeded -NoTypeInformation | Select-Object -Skip 1
            if ($islinux) { $RTIAttendance +=  "`r`n" }
            if (Test-Path "$currentPath\attendance_overrides.ps1") {
                $RTIAttendance = Modify-Attendance -rawAttendance $RTIAttendance
            }
            

            Invoke-RestMethod `
                -Uri "https://rtischeduler.com/data-export-api/schools/$($rti_building_number)/attendance/finalize-by-date?date=$(Get-Date -Format "yyyy-MM-dd")" `
                -Headers @{ "rti-api-token" = "$($RTIToken)" } `
                -Method Post
        }
    }

}

if ($uploadAttendance) {

    if ((Invoke-eSPExecuteSearch -SearchType UPLOADDEF | Select-Object -ExpandProperty interface_id) -notcontains 'ESMU6') {
        Write-Error "Missing the ESMU6 Upload Definition in eSchool." -ErrorAction Stop
    }

    $RTIAttendance | Out-File "exports\RTI_Scheduler\attendance_upload.csv" -Force
    Submit-eSPFile -InFile "exports\RTI_Scheduler\attendance_upload.csv"
    Invoke-eSPUploadDefinition -InterfaceID ESMU6 -RunMode $RunMode -InsertNewRecords -DoNotUpdateExistingRecords -Wait
}
