Configuration TLS12 {
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Node 'localhost' {
        Registry Tls12_ClientDisabled {
            Key = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
            ValueName = "DisabledByDefault"
            ValueData = 0
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Tls12_ClientEnabled {
            Key = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
            ValueName = "Enabled"
            ValueData = 4294967295
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Tls12_ServerDisabled {
            Key = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
            ValueName = "DisabledByDefault"
            ValueData = 0
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Tls12_ServerEnabled {
            Key = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
            ValueName = "Enabled"
            ValueData = 4294967295
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework20_SystemDefaultTlsVersions {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\.NETFramework\v2.0.50727"
            ValueName = "SystemDefaultTlsVersions"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework20_SchUseStrongCrypto {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\.NETFramework\v2.0.50727"
            ValueName = "SchUseStrongCrypto"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework40_SystemDefaultTlsVersions {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
            ValueName = "SystemDefaultTlsVersions"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework40_SchUseStrongCrypto {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
            ValueName = "SchUseStrongCrypto"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework20WOW_SystemDefaultTlsVersions {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v2.0.50727"
            ValueName = "SystemDefaultTlsVersions"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework20WOW_SchUseStrongCrypto {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v2.0.50727"
            ValueName = "SchUseStrongCrypto"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework40WOW_SystemDefaultTlsVersions {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
            ValueName = "SystemDefaultTlsVersions"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry Framework40WOW_SchUseStrongCrypto {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
            ValueName = "SchUseStrongCrypto"
            ValueData = 1
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry WinHttp_DefaultSecureProtocols {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"
            ValueName = "DefaultSecureProtocols"
            ValueData = 2688
            ValueType = 'Dword'
            Ensure = 'Present'
        }
        Registry WinHttpWOW_DefaultSecureProtocols {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"
            ValueName = "DefaultSecureProtocols"
            ValueData = 2688
            ValueType = 'Dword'
            Ensure = 'Present'
        }
    }
}