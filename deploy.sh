#!/bin/bash
set -e

RESOURCE_GROUP_BASE="rg-bifrost"
# Retirámos a West Europe do topo para não perderes tempo; tentamos logo Irlanda ou França
CANDIDATE_REGIONS=("northeurope" "francecentral" "uksouth")

echo "========================================================================="
echo "🎯 BIFROST: A ORQUESTRAR INFRAESTRUTURA DIRETAMENTE NAS REGIÕES ALTERNATIVAS"
echo "========================================================================="

TARGET_REGION=""

for REGION in "${CANDIDATE_REGIONS[@]}"; do
    echo "[*] A testar deploy direto em: $REGION..."
    RESOURCE_GROUP="${RESOURCE_GROUP_BASE}-${REGION}"
    
    cd ~/project-bifrost/terraform
    rm -f terraform.tfstate terraform.tfstate.backup
    
    # Tenta aplicar diretamente. Se a Azure rejeitar, o script apanha a falha e avança para a próxima região imediatamente
    if terraform apply -var="location=$REGION" -var="rg_name=$RESOURCE_GROUP" -auto-approve; then
        echo " -> ✅ DEPLOY COM SUCESSO EM $REGION!"
        TARGET_REGION=$REGION
        break
    else
        echo " -> ❌ Sem recursos em $REGION. A limpar e a saltar..."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait || true
    fi
done

if [ -z "$TARGET_REGION" ]; then
    echo "❌ [ERRO CRÍTICO] Falha total em todas as regiões europeias. Capacidade da Azure esgotada."
    exit 1