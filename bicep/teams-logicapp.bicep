// =============================================================================
//  Nimbus.BitLockerGroupSync - teams-logicapp.bicep
//  Logic App (Consumption) che riceve sia il common alert schema dall'Action
//  Group sia le modifiche membership dal runbook e posta una Adaptive Card su
//  un canale Teams (URL di tipo "Workflows" / Power Automate).
// =============================================================================

targetScope = 'resourceGroup'

@description('Region della Logic App.')
param location string

@description('Nome della Logic App.')
param name string = 'logic-bitlocker-teams'

@description('URL del canale Teams (Workflows / Power Automate) a cui postare la card. Vuoto = POST disabilitato.')
@secure()
param teamsWebhookUrl string = ''

@description('Tag applicati alla risorsa.')
param tags object = {}

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        teamsWebhookUrl: {
          type: 'SecureString'
        }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                data: {
                  type: 'object'
                }
              }
            }
          }
        }
      }
      actions: {
        Post_Runbook_Notification: {
          type: 'If'
          runAfter: {}
          expression: {
            and: [
              {
                not: [
                  {
                    equals: [
                      '@parameters(\'teamsWebhookUrl\')'
                      ''
                    ]
                  }
                ]
              }
              {
                equals: [
                  '@triggerBody()?[\'solution\']'
                  'Nimbus.BitLockerGroupSync'
                ]
              }
            ]
          }
          actions: {
            Post_runbook_adaptive_card: {
              type: 'Http'
              inputs: {
                method: 'POST'
                uri: '@parameters(\'teamsWebhookUrl\')'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  type: 'message'
                  attachments: [
                    {
                      contentType: 'application/vnd.microsoft.card.adaptive'
                      content: {
                        '$schema': 'http://adaptivecards.io/schemas/adaptive-card.json'
                        type: 'AdaptiveCard'
                        version: '1.4'
                        msteams: {
                          width: 'Full'
                        }
                        body: [
                          {
                            type: 'TextBlock'
                            size: 'Large'
                            weight: 'Bolder'
                            text: '🔐 BitLocker Group Sync'
                            wrap: true
                          }
                          {
                            type: 'TextBlock'
                            text: '@{triggerBody()?[\'event\']}'
                            weight: 'Bolder'
                            wrap: true
                            spacing: 'None'
                          }
                          {
                            type: 'FactSet'
                            facts: [
                              {
                                title: 'Aggiunti'
                                value: '@{string(triggerBody()?[\'added\'])}'
                              }
                              {
                                title: 'Rimossi'
                                value: '@{string(triggerBody()?[\'removed\'])}'
                              }
                              {
                                title: 'Device valutati'
                                value: '@{string(triggerBody()?[\'deviceCount\'])}'
                              }
                              {
                                title: 'Errori'
                                value: '@{string(triggerBody()?[\'errors\'])}'
                              }
                            ]
                          }
                          {
                            type: 'TextBlock'
                            text: '@{triggerBody()?[\'changeText\']}'
                            wrap: true
                            separator: true
                          }
                          {
                            type: 'TextBlock'
                            text: 'Eseguito: @{triggerBody()?[\'timestamp\']}'
                            wrap: true
                            isSubtle: true
                            spacing: 'Small'
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
          else: {
            actions: {}
          }
        }
        Post_Azure_Monitor_Alert: {
          type: 'If'
          runAfter: {}
          expression: {
            and: [
              {
                not: [
                  {
                    equals: [
                      '@parameters(\'teamsWebhookUrl\')'
                      ''
                    ]
                  }
                ]
              }
              {
                not: [
                  {
                    equals: [
                      '@triggerBody()?[\'solution\']'
                      'Nimbus.BitLockerGroupSync'
                    ]
                  }
                ]
              }
              {
                not: [
                  {
                    equals: [
                      '@triggerBody()?[\'data\']?[\'essentials\']'
                      null
                    ]
                  }
                ]
              }
            ]
          }
          actions: {
            Post_monitor_adaptive_card: {
              type: 'Http'
              inputs: {
                method: 'POST'
                uri: '@parameters(\'teamsWebhookUrl\')'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  type: 'message'
                  attachments: [
                    {
                      contentType: 'application/vnd.microsoft.card.adaptive'
                      content: {
                        '$schema': 'http://adaptivecards.io/schemas/adaptive-card.json'
                        type: 'AdaptiveCard'
                        version: '1.4'
                        msteams: {
                          width: 'Full'
                        }
                        body: [
                          {
                            type: 'TextBlock'
                            size: 'Large'
                            weight: 'Bolder'
                            text: '🔐 BitLocker Sync — @{triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\']}'
                            wrap: true
                          }
                          {
                            type: 'TextBlock'
                            text: '@{triggerBody()?[\'data\']?[\'essentials\']?[\'alertRule\']}'
                            weight: 'Bolder'
                            wrap: true
                            spacing: 'None'
                          }
                          {
                            type: 'FactSet'
                            facts: [
                              {
                                title: 'Severità'
                                value: '@{triggerBody()?[\'data\']?[\'essentials\']?[\'severity\']}'
                              }
                              {
                                title: 'Stato'
                                value: '@{triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\']}'
                              }
                              {
                                title: 'Segnale'
                                value: '@{triggerBody()?[\'data\']?[\'essentials\']?[\'signalType\']}'
                              }
                              {
                                title: 'Scattato (UTC)'
                                value: '@{triggerBody()?[\'data\']?[\'essentials\']?[\'firedDateTime\']}'
                              }
                            ]
                          }
                          {
                            type: 'TextBlock'
                            text: '@{triggerBody()?[\'data\']?[\'essentials\']?[\'description\']}'
                            wrap: true
                            isSubtle: true
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
          else: {
            actions: {}
          }
        }
      }
    }
    parameters: {
      teamsWebhookUrl: {
        value: teamsWebhookUrl
      }
    }
  }
}

@description('URL di callback del trigger HTTP: da usare come serviceUri del webhook dell\'Action Group.')
#disable-next-line outputs-should-not-contain-secrets
@secure()
output triggerUrl string = listCallbackUrl('${workflow.id}/triggers/manual', '2019-05-01').value

@description('Resource id della Logic App.')
output workflowId string = workflow.id
