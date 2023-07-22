#sample Dsc configuration that sets registry value
Configuration Test {
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Node 'localhost' {
        Registry SampleDsc {
            Key = "HKEY_LOCAL_MACHINE\Software\Test"
            ValueName = "TestValue"
            ValueData = 0
            ValueType = 'Dword'
            Ensure = 'Present'
        }
    }
}