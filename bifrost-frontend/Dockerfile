FROM nginx:alpine
 
# Copia o teu código estático diretamente para o diretório servido pelo Nginx.
# Isto acontece em BUILD TIME - a imagem final já contém o teu index.html,
# não depende de nenhum passo de arranque para "injetar" ficheiros.
COPY index.html /usr/share/nginx/html/index.html
COPY logo.png /usr/share/nginx/html/logo.png
 
# nginx:alpine já expõe a porta 80 e já tem CMD ["nginx", "-g", "daemon off;"]
# definido na imagem base - não precisamos de startup script nenhum.
EXPOSE 80