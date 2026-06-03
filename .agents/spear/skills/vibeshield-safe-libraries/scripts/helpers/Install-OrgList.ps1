function Get-ValidCfsOrganization {
    <#
    .SYNOPSIS
        Returns the list of known internal Microsoft ADO organizations.

    .DESCRIPTION
        Provides a canonical, case-insensitive list of Azure DevOps organization
        names that are known to be backed by CFS (Centralized Feed Service).
        This list is the single source of truth used by all feed config installers
        (NuGet, npm, pip) to validate existing feed configurations.

    .OUTPUTS
        System.String[] - Array of valid CFS organization names.

    .EXAMPLE
        $orgs = Get-ValidCfsOrganization
        if ('mseng' -iin $orgs) { Write-Host 'Valid org' }

    .NOTES
        Maintainability: Track freshness by git history on this file.
        Case-insensitive: Callers should use -iin or -inotin for comparison.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param()

    return @(
        '1esgitops'
        '1ESPipelineTemplates-PPE'
        '1ESSecurity'
        'acctt'
        'azurecom'
        'AzureCSI'
        'azurefrontdoor'
        'bapfundamentals'
        'ceacc'
        'ceapex'
        'CELA-Lit'
        'cesis'
        'CSECodeHub'
        'dev-mc'
        'domoreexp'
        'dynamicscrm'
        'dynamicssmb2'
        'ecsapprovals'
        'IdentityDivision'
        'mas-bug-lib'
        'microsoft'
        'MicrosoftIT'
        'msazuredev'
        'mscodehub'
        'msdata'
        'msdyneng'
        'mseng'
        'msirt'
        'msresearch'
        'O365Exchange'
        'office'
        'onebranch'
        'oneCELA'
        'OneCST'
        'onedrive'
        'ossmsft'
        'powerbi'
        'PowerShellForEngineers'
        'PRAOps'
        'prssdev'
        'Regulated-Industries'
        'securityassurance'
        'SecurityTools'
        'SFIOPS'
        'Supportability'
        'VulnMGMT'
    )
}
