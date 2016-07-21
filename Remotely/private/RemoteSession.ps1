function CopyStreams
{
    param
    (
        [Parameter(Position=0, Mandatory=$true)] 
        $inputStream
    ) 

    $outStream = New-Object 'System.Management.Automation.PSDataCollection[PSObject]'

    foreach($item in $inputStream)
    {
        $outStream.Add($item)
    }

    $outStream.Complete()

    ,$outStream
}

function AddArgumentListtoSessionVars {
	[CmdletBinding()]
	param
    (
        [Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()] $session
    )
	$InvokeCommandParams= @{
		Scriptblock={
						if ($PSSenderInfo.ApplicationArguments.Keys -ne 'PSVersionTable')  {
							# there are arguments passed to the session other than PSversionTable, add them to the current session
							$PSSenderInfo.ApplicationArguments.Keys -ne 'PSversionTable' |
								Foreach-Object -Process {
									New-Variable -Name $PSitem -Value  $PSSenderInfo.ApplicationArguments[$PSitem] -Force
								}
						}
					};
		Session = $session;
		ErrorAction = 'Stop';
	}
	Invoke-Command 	@InvokeCommandParams
}

function CreateSessions
{
	[CmdletBinding(DefaultParameterSetName='Computername')]
    param
    (
        [Parameter(Mandatory, ParameterSetName='ComputerName')]
        [string[]] $Nodes,

        [Parameter()]
        $CredentialHash,

		[Parameter()]
		[hashtable]$ArgumentList,

		[Parameter(ParameterSetName='ConfigurationData')]
		[HashTable]$ConfigData
    )

	# try to see if there are already open PSSessions, which are available
	$existingPSSessions = @(Get-PSSession -Name Remotely* | Where-Object -FilterScript { ($PSitem.State -eq 'Opened') -and ($PSitem.Availability -eq 'available')})
	Switch -Exact ($PSCmdlet.ParameterSetName) {
		'ComputerName' {
			
			foreach($Node in $Nodes)
			{ 
				if(-not $Remotely.SessionHashTable.ContainsKey($Node))
				{                                   
					$sessionName = "Remotely-" + $Node 
					$existingPSSession = $existingPSSessions | Where-Object -Property Name -eq $SessionName  | select-Object -First 1                        
					if ($existingPSSession) {
						$sessionInfo = CreateSessionInfo -Session $existingPSSession	
					}
					else {
						if ($CredentialHash -and $CredentialHash[$Node]) {
							$sessionInfo = CreateSessionInfo -Session (New-PSSession -ComputerName $Node -Name $sessionName -Credential $CredentialHash[$node] -SessionOption $PSSessionOption) -Credential $CredentialHash[$node]
						}
						else {
							$sessionInfo = CreateSessionInfo -Session (New-PSSession -ComputerName $Node -Name $sessionName -SessionOption $PSSessionOption)  
						}
					}
					$Remotely.SessionHashTable.Add($node, $sessionInfo)              
				}               
			}
			break
		}
		'ConfigurationData' {
			# since this is Configuration data parameter set, which means it was supplied.
			# Call Clear-RemoteSession
			foreach ($node in $ConfigData.AllNodes) {
				$argumentList = $Script:argumentList.clone()
				$argumentList.Add('Node',$node) # Add this as an argument list, so that it is availabe as $Node in remote session
				
                if( $Remotely.SessionHashTable.ContainsKey($Node.NodeName)) {
					 #-or ($Remotely.SessionHashTable.ContainsKey("[$($Node.NodeName)]"))) 
                    # node present in the hash table, no need to create another session. Just re-intialize the variables in the session, added second condition for IPv6Addresse
                    ReinitializeSession -SessionInfo $Remotely.sessionHashTable[$node.NodeName] -ArgumentList $argumentList
                }
                else { 
				    # SessionHashtable does not have an entry                              
					$sessionName = "Remotely-" + $Node.NodeName 
                    $PSSessionOption = New-PSSessionOption -ApplicationArguments $argumentList  -NoMachineProfile
					$existingPSSession = $existingPSSessions | Where-Object -Property Name -eq $SessionName  | select-Object -First 1                     
					if ($existingPSSession) {
                        # if there is an open PSSession to the node then use it to create Session info object
						$sessionInfo = CreateSessionInfo -Session $existingPSSession
                        ReinitializeSession -SessionInfo $sessionInfo -ArgumentList $argumentList	
					}
                    else {
					    if ($node.Credential) {
						    # if the node has a key called credential set then use it to create the pssession, First priroity
                            [ValidateNotNullOrEmpty()]$session = New-PSSession -ComputerName $Node.NodeName -Name $sessionName -Credential $node.Credential -SessionOption $PSSessionOption
                            [ValidateNotNullOrEmpty()]$credential = $node.Credential
						    [ValidateNotNullOrEmpty()]$sessionInfo = CreateSessionInfo -Session $session -Credential $credential
					    }
					    elseif ($CredentialHash -and $CredentialHash[$Node.NodeName]) {
                            [ValidateNotNullOrEmpty()]$session = New-PSSession -ComputerName $Node.NodeName -Name $sessionName -Credential $CredentialHash[$node.NodeName] -SessionOption $PSSessionOption
                            [ValidateNotNullOrEmpty()]$credential = $CredentialHash[$node.NodeName]
						    $sessionInfo = CreateSessionInfo -Session $session -Credential $credential
					    }
					    else {
						    $sessionInfo = CreateSessionInfo -Session (New-PSSession -ComputerName $Node.NodeName -Name $sessionName -SessionOption $PSSessionOption)
					    }
					
                        AddArgumentListtoSessionVars -session $sessionInfo.Session
                    }
					$Remotely.SessionHashTable.Add($($node.NodeName), $sessionInfo)
				}
				
			}
			break
		}
	}
    
}

function CreateLocalSession
{    
    param(
        [Parameter(Position=0)] $Node = 'localhost'
    )

    if(-not $Remotely.SessionHashTable.ContainsKey($Node))
    {
        $sessionInfo = CreateSessionInfo -Session (New-PSSession -ComputerName $Node -Name $sessionName)
        $Remotely.SessionHashTable.Add($Node, $sessionInfo)
    } 
}

function CreateSessionInfo
{
    param(
        [Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Runspaces.PSSession] $Session,

        [Parameter(Position=1)]
        [pscredential] $Credential
    )
    return [PSCustomObject] @{ Session = $Session; Credential = $Credential}
}

function CheckAndReconnect
{
    param
    (
        [Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()] $sessionInfo
    )

    if($sessionInfo.Session.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened)
    {
        Write-Verbose "Unexpected session state: $sessionInfo.Session.State for machine $($sessionInfo.Session.ComputerName). Re-creating session" 
        if($sessionInfo.Session.ComputerName -ne 'localhost')
        {
            if ($sessionInfo.Credential)
            {
                $sessionInfo.Session = New-PSSession -ComputerName $sessionInfo.Session.ComputerName -Credential $sessionInfo.Credential
            }
            else
            {
                $sessionInfo.Session = New-PSSession -ComputerName $sessionInfo.Session.ComputerName
            }
        }
        else
        {
            $sessionInfo.Session = New-PSSession -ComputerName 'localhost'
        }
    }
}

# add this function to re-initialize the entire argument list (along with $node var) in the remote session
Function ReinitializeSession {
	[CmdletBinding()]
	param(
		[Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()] $sessionInfo,

		[Parameter(Position=1, Mandatory=$true)]
		[ValidateNotNullOrEmpty()] 
		[HashTable]$ArgumentList
	)
	TRY {
		$sessionInfo.Session.Runspace.ResetRunspaceState() # reset the runspace state
	}
	CATCH {
		# TO DO : above fails some time. Check why.
	}
	Invoke-Command -Session $sessionInfo.Session -ArgumentList $argumentList -ScriptBlock {
		param($arglist)
		foreach ($enum in $arglist.GetEnumerator()) {
			New-Variable -Name $enum.Key -Value $enum.Value -Force
		}
	}
}
 