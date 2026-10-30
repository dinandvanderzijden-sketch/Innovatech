FROM nginx:1.27-alpine
ARG GIT_SHA=dev
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html /usr/share/nginx/html
RUN echo "$GIT_SHA" > /usr/share/nginx/html/version.txt
EXPOSE 80
