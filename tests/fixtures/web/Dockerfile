# Minimal web server used by the selftest to exercise the composite actions.
FROM busybox:1.37

RUN mkdir -p /www \
 && echo "UP" > /www/health \
 && echo "Hello from the selftest fixture" > /www/index.html

USER 65534
EXPOSE 8080
CMD ["httpd", "-f", "-v", "-p", "8080", "-h", "/www"]
