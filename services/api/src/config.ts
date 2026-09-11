export type RuntimeConfig = {
  port: number;
  databaseUrl: string | null;
  redisUrl: string | null;
  providerKeys: {
    national: boolean;
    seoul: boolean;
    ulsan: boolean;
  };
  missingRequired: string[];
  missingProviderKeys: string[];
};

const REQUIRED_ENV = ["DATABASE_URL", "REDIS_URL"] as const;
const PROVIDER_ENV = ["NATIONAL_SERVICE_KEY", "SEOUL_API_KEY", "ULSAN_SERVICE_KEY"] as const;

function optionalValue(env: NodeJS.ProcessEnv, key: string): string | null {
  const value = env[key]?.trim();
  return value && value.length > 0 ? value : null;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): RuntimeConfig {
  const missingRequired = REQUIRED_ENV.filter((key) => optionalValue(env, key) === null);
  const missingProviderKeys = PROVIDER_ENV.filter((key) => optionalValue(env, key) === null);
  const rawPort = env.PORT === undefined ? null : env.PORT.trim();
  const port = rawPort === null ? 3000 : Number(rawPort);

  if ((rawPort !== null && !/^[0-9]+$/u.test(rawPort)) || !Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error("PORT must be an integer TCP port between 1 and 65535");
  }

  return {
    port,
    databaseUrl: optionalValue(env, "DATABASE_URL"),
    redisUrl: optionalValue(env, "REDIS_URL"),
    providerKeys: {
      national: optionalValue(env, "NATIONAL_SERVICE_KEY") !== null,
      seoul: optionalValue(env, "SEOUL_API_KEY") !== null,
      ulsan: optionalValue(env, "ULSAN_SERVICE_KEY") !== null
    },
    missingRequired,
    missingProviderKeys
  };
}
