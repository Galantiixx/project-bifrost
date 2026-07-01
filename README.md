# 🛡️ Projeto Bifrost // Cloud Recon Intelligence

> **Plataforma Serverless Containerizada de Reconhecimento Automatizado e Auditoria Ativa de Perímetro**

[cite_start]O **Projeto Bifrost** é uma aplicação Web descentralizada concebida para demonstrar a aplicação prática de arquiteturas elásticas e modernas em cenários de segurança ofensiva (*Red Teams*)[cite: 6, 8].

[cite_start]Ao delegar os varrimentos prolongados de infraestrutura para um modelo de **Computação Serverless (Cloud)** e isolar a interface de gestão dentro de um **Contentor Docker**, a plataforma otimiza os recursos locais do analista, centralizando e estruturando as informações recolhidas diretamente num cluster NoSQL[cite: 11, 12, 13].

---

## 🎓 Envolvência Académica

[cite_start]Este mini-projeto foi integralmente desenvolvido, documentado e defendido no âmbito do percurso académico:

* [cite_start]**Instituição:** Instituto Politécnico de Castelo Branco (IPCB) [cite: 1, 2]
* [cite_start]**Escola:** Escola Superior de Tecnologia (EST) [cite: 3, 4]
* [cite_start]**Curso:** Licenciatura em Engenharia Informática [cite: 4]
* [cite_start]**Unidade Curricular:** Computação em Nuvem (CN) [cite: 5]
* **Ano Letivo:** 1.º Ano // 2.º Semestre

---

## 🧬 Arquitetura da Infraestrutura Cloud

[cite_start]O ecossistema adota uma abordagem puramente baseada em **Infraestrutura como Código (IaC)** através do **Terraform**, sendo composto pelos seguintes serviços integrados na Microsoft Azure[cite: 8, 10]:

1.  [cite_start]**Camada de Apresentação (Frontend Containerizado):** A interface tática operacional (com o tema *Red Team Crimson*) encontra-se empacotada dentro de um **Docker Container** (imagem ultra-leve Nginx), alojada de forma isolada no **Azure App Service (Web App for Containers)**.
2.  [cite_start]**Camada de Processamento (Backend Serverless):** O `ReconEngine` é executado numa **Azure Function (Serverless Computing)** baseada em Node.js. Através de programação assíncrona concorrente (`Promise.all`), efetua varrimentos paralelos de sockets TCP contra as portas de serviços comuns mais críticas do perímetro e resolve DNS em frações de segundo de forma assíncrona.
3.  [cite_start]**Camada de Armazenamento NoSQL:** Utilização do **Azure Cosmos DB** (API NoSQL) para o armazenamento e indexação dinâmica de dados estruturados (historial de alvos, timestamps e listas de portas abertas)[cite: 11].
4.  [cite_start]**Camada de Arquivo (Blob Storage):** Utilização do **Azure Blob Storage** (contentor `historico-bruto`) para a salvaguarda e persistência dos relatórios brutos em formato `.json`, garantindo a separação rigorosa de logs exigida[cite: 14].
5.  **Ambiente de Teste (Sandbox):** Uma **Máquina Virtual Linux (Ubuntu Server)** com um IP público estático, instanciada na mesma subscrição para servir de cobaia legítima e controlada para os testes de penetração de rede.

---

## 🛠️ Instruções de Setup & Orquestração (Guia para o Docente)

[cite_start]O projeto foi totalmente blindado contra a volatilidade das sessões da Azure Cloud Shell. [cite_start]Toda a interligação de chaves criptográficas, permissões de CORS e variáveis de ambiente foi automatizada num script de CI/CD autónomo.

Para garantir um deploy limpo e mitigar conflitos de concorrência de nomes ou limites de quotas na Azure, siga estes passos sequenciais no terminal:

### Passo 1: Limpar Recursos Antigos da Azure (Recomendado)
Para evitar conflitos com deploys anteriores pendentes, execute a remoção forçada do Grupo de Recursos:
```bash
az group delete --name rg-bifrost-final --yes --no-wait

### Passo 2: Atribuir Permissões ao Script (chmod)
Por questões de segurança nativas do ambiente Linux, os scripts descarregados do Git não trazem privilégios de execução ativos por omissão. É obrigatório conceder permissões de execução ao ficheiro orquestrador utilizando o utilitário `chmod` antes de o tentar correr:
```bash
cd ~/project-bifrost
chmod +x deploy.sh

### Passo 3: Executar o Full Deploy Autónomo
Com as permissões atribuídas, inicialize o script de automação para construir toda a infraestrutura e fazer o deploy das aplicações em simultâneo:
```bash
./deploy.sh