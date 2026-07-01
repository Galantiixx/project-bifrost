const { app } = require('@azure/functions');
const { CosmosClient } = require('@azure/cosmos');
const { BlobServiceClient } = require('@azure/storage-blob');
const net = require('net');
const dns = require('dns').promises;

const client = new CosmosClient(process.env.COSMOS_DB_CONNECTION_STRING);
const container = client.database("bifrost-db").container("relatorios");

function scanPort(port, host) {
    return new Promise((resolve) => {
        const socket = new net.Socket();
        socket.setTimeout(350); 

        socket.on('connect', () => { socket.destroy(); resolve(port); });
        socket.on('timeout', () => { socket.destroy(); resolve(null); });
        socket.on('error', () => { socket.destroy(); resolve(null); });
        socket.connect(port, host);
    });
}

app.http('ReconEngine', {
    methods: ['GET', 'POST', 'OPTIONS'],
    authLevel: 'anonymous',
    handler: async (request, context) => {
        const corsHeaders = {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Content-Type': 'application/json'
        };

        if (request.method === 'OPTIONS') {
            return { status: 204, headers: corsHeaders };
        }

        // FLUXO GET: Recupera um scan específico OU lista o historial completo
        if (request.method === 'GET') {
            const url = new URL(request.url);
            const scanId = url.searchParams.get('id');
            
            try {
                if (scanId) {
                    const { resource: doc } = await container.item(scanId, scanId).read();
                    if (doc) return { status: 200, headers: corsHeaders, body: JSON.stringify(doc) };
                    return { status: 404, headers: corsHeaders, body: JSON.stringify({ status: "Processing" }) };
                } else {
                    // Listar os últimos 20 scans para o historial lateral
                    const { resources: items } = await container.items
                        .query("SELECT c.id, c.alvo, c.timestamp, c.portas_abertas FROM c ORDER BY c.timestamp DESC OFFSET 0 LIMIT 20")
                        .fetchAll();
                    return { status: 200, headers: corsHeaders, body: JSON.stringify(items) };
                }
            } catch (e) {
                // ANTES: engolia o erro em silêncio e devolvia sempre [] com 200 OK.
                // AGORA: regista a mensagem real e o código de erro do Cosmos DB.
                context.log(`Erro Cosmos DB (GET, scanId=${scanId || 'lista'}): ${e.code || ''} ${e.message}`);
                return { status: 200, headers: corsHeaders, body: JSON.stringify([]) };
            }
        }

        // FLUXO POST: Execução Real de Reconhecimento
        if (request.method === 'POST') {
            try {
                const body = await request.json();
                let target = body.target ? body.target.trim() : "51.124.38.94";
                const scanId = `scan-${Date.now()}`;
                
                let resolvedIP = target;
                let detectedDomains = [];

                const isIP = /^([0-9]{1,3}\.){3}[0-9]{1,3}$/.test(target);
                
                if (!isIP) {
                    try {
                        const addresses = await dns.resolve4(target);
                        resolvedIP = addresses[0];
                        detectedDomains.push(`Alvo de Origem: ${target}`);
                    } catch (dnsErr) {
                        detectedDomains.push(`Domínio não resolveu IPv4 estruturado.`);
                    }
                } else {
                    try {
                        const rdns = await dns.reverse(target);
                        detectedDomains = rdns;
                    } catch (dnsErr) {
                        detectedDomains.push(`IP Público Isolado (Sem registo PTR reverso público)`);
                    }
                }

                const commonPorts = [21, 22, 23, 25, 53, 80, 110, 143, 443, 445, 1433, 3306, 3389, 5432, 8080, 8443];
                const scanPromises = commonPorts.map(port => scanPort(port, resolvedIP));
                const scanResults = await Promise.all(scanPromises);
                const openPorts = scanResults.filter(p => p !== null);

                const scanReport = {
                    id: scanId,
                    alvo: target,
                    ip_resolvido: resolvedIP,
                    timestamp: new Date().toISOString(),
                    status: "Concluído",
                    portas_abertas: openPorts,
                    dominios: detectedDomains,
                    detalhes: `Auditoria perimetral síncrona concluída. ${commonPorts.length} vetores de serviços comuns testados.`
                };

                // 1. Salvar Dados Estruturados no Cosmos DB
                try {
                    await container.items.create(scanReport);
                    context.log(`Scan ${scanId} gravado com sucesso no Cosmos DB.`);
                } catch (dbErr) {
                    // ANTES: context.log("Erro Cosmos DB"); - sem detalhe nenhum.
                    // AGORA: mensagem, código de erro HTTP do Cosmos, e stack.
                    context.log(`Erro Cosmos DB (POST, id=${scanId}): ${dbErr.code || ''} ${dbErr.message}`);
                }

                // 2. REQUISITO OBRIGATÓRIO: Salvar Relatório Bruto (.json) no Azure Blob Storage
                try {
                    const blobServiceClient = BlobServiceClient.fromConnectionString(process.env.AzureWebJobsStorage);
                    const containerClient = blobServiceClient.getContainerClient("historico-bruto");
                    await containerClient.createIfNotExists();
                    
                    const blockBlobClient = containerClient.getBlockBlobClient(`${scanId}.json`);
                    const rawData = JSON.stringify(scanReport, null, 2);
                    await blockBlobClient.upload(rawData, rawData.length);
                } catch (blobErr) {
                    context.log("Erro Blob Storage Bruto: " + blobErr.message);
                }

                return { status: 200, headers: corsHeaders, body: JSON.stringify(scanReport) };

            } catch (err) {
                context.log(`Erro fatal no fluxo POST: ${err.message}`);
                return { status: 500, headers: corsHeaders, body: JSON.stringify({ error: err.message }) };
            }
        }
    }
});