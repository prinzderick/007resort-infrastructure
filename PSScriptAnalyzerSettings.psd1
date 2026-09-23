@{
    # Errors AND warnings fail CI. The excluded rules are noise for this codebase:
    #  - ShouldProcess: every mutating step is guarded by an explicit -DryRun switch (Invoke-R007Step) instead.
    #  - SingularNouns: internal step functions (Install-Packages, ...) are not exported cmdlets.
    #  - ReviewUnusedParameter: false positives - parameters are consumed inside scriptblocks passed to Invoke-R007Step.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSReviewUnusedParameter'
    )
}
