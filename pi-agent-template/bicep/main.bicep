// =============================================================================
// Pi Coding Agent - Azure VM Infrastructure
// Deploy with: az deployment group create --resource-group <rg> --template-file main.bicep
// Preview with: az deployment group what-if --resource-group <rg> --template-file main.bicep
// =============================================================================

@description('VM name')
param vmName string = 'vm-antti-ai-coding-agent'

@description('Location (defaults to resource group location)')
param location string = resourceGroup().location

@description('VM size')
param vmSize string = 'Standard_B4ms'

@description('Admin username')
param adminUsername string = 'azureuser'

@description('SSH public key content')
@secure()
param sshPublicKey string

@description('OS disk size in GB')
param diskSizeGb int = 64

@description('Daily auto-shutdown time UTC in HHMM format')
param autoShutdownTime string = '2200'

@description('Owner tag')
param tagOwner string = 'antti.kiiskinen@adafy.com'

@description('Environment tag')
param tagEnvironment string = 'dev'

@description('Project tag')
param tagProject string = 'ai-coding-agent'

// -----------------------------------------------------------------------------

var tags = {
  Owner: tagOwner
  Environment: tagEnvironment
  Project: tagProject
}

var nsgName             = '${vmName}-nsg'
var vnetName            = '${vmName}-vnet'
var subnetName          = 'default'
var publicIpName        = '${vmName}-pip'
var nicName             = '${vmName}-nic'
var automationName      = '${vmName}-auto'

var vmContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
)

// --- Network Security Group --------------------------------------------------

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// --- Virtual Network ---------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// --- Public IP ---------------------------------------------------------------

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// --- Network Interface -------------------------------------------------------

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/${subnetName}' }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

// --- Virtual Machine ---------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: diskSizeGb
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

// --- Daily Auto-Shutdown -----------------------------------------------------

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

// --- Automation Account (for CPU idle shutdown runbook) ----------------------

resource automationAccount 'Microsoft.Automation/automationAccounts@2022-08-08' = {
  name: automationName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: { name: 'Basic' }
  }
}

resource rgVariable 'Microsoft.Automation/automationAccounts/variables@2022-08-08' = {
  parent: automationAccount
  name: 'ResourceGroup'
  properties: {
    value: '"${resourceGroup().name}"'
    isEncrypted: false
  }
}

resource vmVariable 'Microsoft.Automation/automationAccounts/variables@2022-08-08' = {
  parent: automationAccount
  name: 'VmName'
  properties: {
    value: '"${vmName}"'
    isEncrypted: false
  }
}

// --- Role Assignment: Automation Account can deallocate the VM ---------------

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vm
  name: guid(vm.id, automationAccount.id, vmContributorRoleId)
  properties: {
    roleDefinitionId: vmContributorRoleId
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Outputs -----------------------------------------------------------------

output publicIpAddress string = publicIp.properties.ipAddress
output automationAccountName string = automationAccount.name
output vmResourceId string = vm.id
