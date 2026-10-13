FROM node:22-alpine

WORKDIR /app

COPY package*.json ./
# npm install honours the "overrides" block in package.json (npm >=8.3),
# which pins p-limit to a CommonJS version so @pyroscope/nodejs can require it.
RUN npm install --omit=dev

# Create the unprivileged user first and chown only the app sources via COPY.
# A recursive "chown -R /app" would also copy up every node_modules file into a
# new layer, which hangs on some overlay/ZFS-backed Docker hosts and doubles
# the image size. node_modules stays root-owned and read-only for the app.
RUN addgroup -g 1001 appgroup && \
    adduser -u 1001 -G appgroup -D appuser

COPY --chown=appuser:appgroup . .

USER appuser

EXPOSE 8080

CMD [ "npm", "start" ]
