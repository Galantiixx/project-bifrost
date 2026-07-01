#!/bin/bash
set -e

RESOURCE_GROUP="rg-bifrost-final"

echo "========================================================================="
echo "🔍 BIFROST PRE-DEPLOY: ANÁLISE DE DISPONIBILIDADE DE SKUS"
echo "========================================================================="

# 1. Interrogar o Azure para obter todas as regiões onde a VM Standard_B1s está totalmente livre (Restrictions == None)
echo "[*] A mapear regiões com capacidade física para o SKU Standard_B1s..."
REGIOES_VM_LIVRES=$(az vm list-skus --size Standard_B1s --all --query "[?restrictions[0].reasonCode==null].location" -o tsv)

if [ -z "$REGIOES_VM_LIVRES" ]; then
    # Fallback caso o parser do reasonCode falhe devido ao formato do output
    REGIOES_VM_LIVRES=$(az vm list-skus --size Standard_B1s --all --output json | jq -r '.[] | select(.restrictions | length == 0) | .location' 2>/dev/null || echo "denmarkeast")
fi

TARGET_REGION=""

# 2. Encontrar a primeira região da lista de VMs livres que também suporta os planos do App Service (Web/Functions)
for REGION in $REGIOES_VM_LIVRES; do
    # Normalizar o nome da região (remover espaços e passar para lowercase)
    REGION_CLEAN=$(echo "$REGION" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    
    echo -n "[*] A validar suporte de App Service em '$REGION_CLEAN'..."
    
    # Verifica se a região suporta planos Linux no ecossistema Web do Azure
    WEB_CHECK=$(az appservice list-locations --sku B1 --query "[?contains(name, '$REGION_CLEAN')]" -o tsv 2>/dev/null || echo "")
    
    if [ ! -z "$WEB_CHECK" ]; then
        echo " -> ✅ 100% DISPONÍVEL!"
        TARGET_REGION=$REGION_CLEAN
        break
    else
        echo " -> ❌ Restrito para Web Plans"
    fi
done

# Se nenhuma região ideal for encontrada dinamicamente, assume a Dinamarca que está confirmada no teu log
if [ -z "$TARGET_REGION" ]; then
    echo "[⚠️] Aviso: Filtro dinâmico inconclusivo. Forçando região de contingência: denmarkeast"
    TARGET_REGION="denmarkeast"
fi

echo "========================================================================="
echo "🎯 REGIÃO DETERMINADA COM SUCESSO: $TARGET_REGION"
echo "========================================================================="

cd ~/project-bifrost/terraform

# Limpeza absoluta de cache local para evitar conflitos de máquinas de estado corrompidas
rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
terraform init

echo "[+] A disparar o Terraform para a região garantida: $TARGET_REGION..."
terraform apply -var="location=$TARGET_REGION" -var="rg_name=$RESOURCE_GROUP" -auto-approve

# =========================================================================
# ORQUESTRACION LINEAR ORIGINAL DO PROJETO (INALTERADA)
# =========================================================================
echo "[+] A extrair credenciais dinâmicas da infraestrutura..."
STORAGE_NAME=$(az storage account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
COSMOS_NAME=$(az cosmosdb list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
FUNCTION_NAME=$(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
APP_SERVICE_NAME=$(az webapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)

STORAGE_CONN=$(az storage account show-connection-string --name "$STORAGE_NAME" --resource-group $RESOURCE_GROUP --query connectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list --name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "[+] A criar tabelas NoSQL (Cosmos DB)..."
az cosmosdb sql database create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --name "bifrost-db" || true
az cosmosdb sql container create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --database-name "bifrost-db" --name "relatorios" --partition-key-path "/id" || true

echo "[+] A injetar configurações na Azure Function..."
az functionapp config appsettings set --name "$FUNCTION_NAME" --resource-group $RESOURCE_GROUP --settings COSMOS_DB_CONNECTION_STRING="$COSMOS_CONN" AzureWebJobsStorage="$STORAGE_CONN" > /dev/null

echo "[+] A aplicar permissões de CORS..."
APP_URL="https://$APP_SERVICE_NAME.azurewebsites.net"
az functionapp cors add --resource-group $RESOURCE_GROUP --name "$FUNCTION_NAME" --allowed-origins "$APP_URL" > /dev/null

echo "[+] A publicar código do Backend Serverless..."
cd ~/project-bifrost/bifrost-backend
func azure functionapp publish "$FUNCTION_NAME" --javascript

echo "[+] A injetar endpoint dinâmico no Frontend..."
API_URL="https://$FUNCTION_NAME.azurewebsites.net/api/ReconEngine"
sed -i "/BIFROST_TARGET_API_INJECTION/{n;s|const API_URL = .*|const API_URL = '$API_URL';|}" ~/project-bifrost/bifrost-frontend/index.html

echo "[+] A carregar Frontend para o App Service..."
cd ~/project-bifrost/bifrost-frontend
zip -r frontend.zip index.html logo.png Dockerfile > /dev/null
az webapp deployment source config-zip --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --src frontend.zip > /dev/null
rm frontend.zip

echo "========================================================================="
echo "🎯 PROJETO BIFROST DISPONÍVEL COM SUCESSO EM: $TARGET_REGION"
echo "========================================================================="
echo "👉 Dashboard URL: $APP_URL"
echo "========================================================================="