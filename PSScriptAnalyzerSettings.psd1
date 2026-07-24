@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # I runbook usano Write-Output/Write-Host per la telemetria dei job Automation.
        'PSAvoidUsingWriteHost',
        # Automation variabili/parametri possono restare non usati a seconda del percorso.
        'PSReviewUnusedParameter',
        # Send-Alert e' best-effort (nessuna mutazione di stato locale da confermare).
        'PSUseShouldProcessForStateChangingFunctions',
        # Write-Log e' l'helper di logging della soluzione (falso positivo).
        'PSAvoidOverwritingBuiltInCmdlets'
    )
}
