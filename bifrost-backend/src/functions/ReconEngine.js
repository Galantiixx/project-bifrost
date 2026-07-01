const { app } = require('@azure/functions');
const { CosmosClient } = require('@azure/cosmos');
const net = require('net');
const dns = require('dns').promises;

const client = new CosmosClient(process.env.COSMOS_DB_CONNECTION_STRING);
const container = client.database("bifrost-db").container("relatorios");

// Sockets TCP concorrentes com timeout agressivo de 350ms para permitir maior robustez
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

        // FLUXO GET: Polling do Cosmos DB
        if (request.method === 'GET') {
            const url = new URL(request.url);
            const scanId = url.searchParams.get('id');
            try {
                const { resource: doc } = await container.item(scanId, scanId).read();
                if (doc) return { status: 200, headers: corsHeaders, body: JSON.stringify(doc) };
            } catch (e) {}
            return { status: 404, headers: corsHeaders, body: JSON.stringify({ status: "Processing" }) };
        }

        // FLUXO POST: O Motor de Auditoria Real
        if (request.method === 'POST') {
            try {
                const body = await request.json();
                let target = body.target ? body.target.trim() : "51.124.38.94";
                const scanId = `scan-${Date.now()}`;
                
                let resolvedIP = target;
                let detectedDomains = [];

                // 1. LÓGICA DE DOMÍNIOS DINÂMICA: Verifica se o utilizador inseriu um domínio ou IP
                const isIP = /^([0-9]{1,3}\.){3}[0-9]{1,3}$/.test(target);
                
                if (!isIP) {
                    try {
                        // Se for um domínio (ex: test.com), resolve o IP real em direto
                        const addresses = await dns.resolve4(target);
                        resolvedIP = addresses[0];
                        detectedDomains.push(`Domínio Alvo: ${target}`);
                    } catch (dnsErr) {
                        detectedDomains.push(`Falha ao resolver domínio: ${target}`);
                    }
                } else {
                    try {
                        // Se for IP, tenta o Reverse DNS real
                        const rdns = await dns.reverse(target);
                        detectedDomains = rdns;
                    } catch (dnsErr) {
                        // Resposta analítica real caso o ISP bloqueie o PTR inverso
                        detectedDomains.push(`IP Público Isolado (Sem registo PTR reverso público)`);
                    }
                }

                // 2. MATRIZ DE PORTAS ROBUSTA (Top Common Services)
                // Expandido para mapear Web, SSH, FTP, Email, Bases de Dados e Proxies comuns
                const commonPorts = [
                    21,  // FTP
                    22,  // SSH
                    23,  // Telnet
                    25,  // SMTP
                    53,  // DNS
                    80,  // HTTP
                    110, // POP3
                    143, // IMAP
                    443, // HTTPS
                    445, // SMB (Exploits clássicos como EternalBlue)
                    1433,// MSSQL
                    3306,// MySQL
                    3389,// RDP (Windows Remote Desktop)
                    5432,// PostgreSQL
                    8080,// HTTP Alternate / Tomcat
                    8443 // HTTPS Alternate
                ];

                // Execução Concorrente usando Promise.all para varrer em frações de segundo
                const scanPromises = commonPorts.map(port => scanPort(port, resolvedIP));
                const scanResults = await Promise.all(scanPromises);
                
                // Filtrar apenas as portas que responderam com sucesso (OPEN)
                const openPorts = scanResults.filter(p => p !== null);

                // 3. CONSOLIDAR RELATÓRIO DINÂMICO REAL
                const scanReport = {
                    id: scanId,
                    alvo: target,
                    ip_resolvido: resolvedIP,
                    timestamp: new Date().toISOString(),
                    status: "Concluído",
                    portas_abertas: openPorts, // Array real vazio ou preenchido conforme a VM responder
                    dominios: detectedDomains,
                    detalhes: `Auditoria perimetral síncrona efetuada sobre ${resolvedIP}. Foram testados ${commonPorts.length} vetores de serviços padrão.`
                };

                // Persistir o resultado real no Cosmos DB
                try {
                    await container.items.create(scanReport);
                } catch (dbErr) {
                    context.log("[COSMOS-ERROR] Falha de persistência.");
                }

                return {
                    status: 200,
                    headers: corsHeaders,
                    body: JSON.stringify(scanReport)
                };

            } catch (err) {
                return { 
                    status: 500, 
                    headers: corsHeaders, 
                    body: JSON.stringify({ error: "Erro na execução do motor: " + err.message }) 
                };
            }
        }
    }
});