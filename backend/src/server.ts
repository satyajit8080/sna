import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";

const config = loadConfig();
const app = await buildApp(config);

// Railway sends SIGTERM on redeploy. Closing cleanly lets in-flight coaching
// requests finish rather than failing mid-response.
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, async () => {
    app.log.info({ signal }, "shutting down");
    await app.close();
    process.exit(0);
  });
}

try {
  // 0.0.0.0 is required inside a container; localhost would be unreachable.
  await app.listen({ port: config.port, host: "0.0.0.0" });
  app.log.info(
    {
      environment: config.environment,
      coach: config.openRouterApiKey ? "configured" : "not configured",
      food: config.usdaApiKey ? "configured" : "not configured",
    },
    "bpcoach backend listening"
  );
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
