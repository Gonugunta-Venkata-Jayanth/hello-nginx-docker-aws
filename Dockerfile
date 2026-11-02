# Small, official base image (~20 MB): only Nginx is needed to serve static files
FROM nginx:1.27-alpine

# Replace the default site (port 80) with one that listens on 8081
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/app.conf
COPY app/ /usr/share/nginx/html/

# Documents the port the container serves on; publish it with -p 8081:8081
EXPOSE 8081

# Lets Docker (and ECS) mark the container unhealthy if Nginx stops answering
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8081/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
