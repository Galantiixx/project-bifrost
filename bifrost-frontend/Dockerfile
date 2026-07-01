# Estágio de execução: Servidor Nginx Web leve
FROM nginx:alpine

# Copiar os ficheiros do teu frontend Crimson para o diretório padrão do Nginx
COPY index.html /usr/share/nginx/html/
COPY logo.png /usr/share/nginx/html/

# Expor a porta padrão HTTP
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]