// =============================================================================
//  Nimbus.BitLockerGroupSync - teams-logicapp.bicep
//  Logic App (Consumption) che riceve il common alert schema dall'Action Group
//  e posta una Adaptive Card su un canale Teams (URL di tipo "Workflows" /
//  Power Automate). Se l'URL Teams e' vuoto, la Logic App non invia nulla
//  (deploy comunque valido: si imposta l'URL in un secondo momento).
// =============================================================================

targetScope = 'resourceGroup'

@description('Region della Logic App.')
param location string

@description('Nome della Logic App.')
param name string = 'logic-bitlocker-teams'

@description('URL del canale Teams (Workflows / Power Automate) a cui postare la card. Vuoto = POST disabilitato.')
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
          type: 'String'
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
        Post_to_Teams: {
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
            ]
          }
          actions: {
            Post_adaptive_card: {
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
output triggerUrl string = listCallbackUrl('${workflow.id}/triggers/manual', '2019-05-01').value

@description('Resource id della Logic App.')
output workflowId string = workflow.id
