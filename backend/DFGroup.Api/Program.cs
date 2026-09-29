using System.Text;
using FluentValidation;
using DFGroup.Api.Configuration;
using DFGroup.Api.Middleware;
using DFGroup.Api.Repositories;
using DFGroup.Api.Services;
using DFGroup.Api.Services.ExchangeRate;
using DFGroup.Api.Validators;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

// Configure Serilog
Log.Logger = new LoggerConfiguration()
    .ReadFrom.Configuration(builder.Configuration)
    .CreateLogger();

builder.Host.UseSerilog();

// Add services to the container
builder.Services.AddControllers()
    .AddJsonOptions(options =>
    {
        options.JsonSerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.SnakeCaseLower;
        options.JsonSerializerOptions.WriteIndented = true;
    });

// Configuration
builder.Services.Configure<ApiSettings>(builder.Configuration.GetSection("ApiSettings"));
builder.Services.Configure<JwtSettings>(builder.Configuration.GetSection("Jwt"));
builder.Services.Configure<GoogleSettings>(builder.Configuration.GetSection("Google"));
builder.Services.AddSingleton(builder.Configuration);

// Database connection
builder.Services.AddSingleton<IDbConnectionFactory>(sp =>
    new SqlConnectionFactory(builder.Configuration.GetConnectionString("DFGroupDb")!));

// Repositories
builder.Services.AddScoped<IFranquiciaRepository, FranquiciaRepository>();
builder.Services.AddScoped<IIngestionRepository, IngestionRepository>();
builder.Services.AddScoped<IDashboardRepository, DashboardRepository>();
builder.Services.AddScoped<IApiKeyRepository, ApiKeyRepository>();
builder.Services.AddScoped<IConexionRepository, ConexionRepository>();
builder.Services.AddScoped<IPreferenciasRepository, PreferenciasRepository>();
builder.Services.AddScoped<IExchangeRateRepository, ExchangeRateRepository>();
builder.Services.AddScoped<IAuthRepository, AuthRepository>();

// Services
builder.Services.AddScoped<IIngestionService, IngestionService>();
builder.Services.AddScoped<IDashboardService, DashboardService>();
builder.Services.AddScoped<IApiKeyService, ApiKeyService>();
builder.Services.AddScoped<IConexionService, ConexionService>();
builder.Services.AddScoped<IAgoraExtractorService, AgoraExtractorService>();
builder.Services.AddScoped<IVinsonExtractorService, VinsonExtractorService>();
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddHttpClient<ITxtParserService, TxtParserService>(client =>
{
    client.Timeout = TimeSpan.FromMinutes(5); // 5 minutes for large file parsing
});

// Exchange Rate Services (Tipo de Cambio)
builder.Services.AddHttpClient<BcraExchangeRateProvider>();
builder.Services.AddHttpClient<ExchangeRateHostProvider>();
builder.Services.AddHttpClient<DolarApiProvider>();
builder.Services.AddScoped<IExchangeRateProvider, BcraExchangeRateProvider>();
builder.Services.AddScoped<IExchangeRateProvider, ExchangeRateHostProvider>();
builder.Services.AddScoped<IExchangeRateProvider, DolarApiProvider>();
builder.Services.AddScoped<IExchangeRateService, ExchangeRateService>();

// Correo saliente. La clave NO esta en appsettings: viene de la variable de
// entorno Smtp__Password, que los lanzadores leen de _secrets.
builder.Services.AddScoped<IMailService, MailService>();

// Background Job para refresh diario de tasas
builder.Services.AddHostedService<ExchangeRateRefreshJob>();

// HttpClient para llamadas a APIs externas (Ágora, Vinson, etc)
builder.Services.AddHttpClient();

// Validators
builder.Services.AddValidatorsFromAssemblyContaining<DailySalesBatchRequestValidator>();

// JWT Authentication
var jwtSettings = builder.Configuration.GetSection("Jwt").Get<JwtSettings>()!;

/* ---------------------------------------------------------------------------
   La clave de firma NO vive en ningun archivo del repositorio: se inyecta por
   la variable de entorno Jwt__Secret, que los .bat de arranque leen de
   C:\PILL-DF\_secrets\webapp_jwt.txt.

   Se valida aca y no mas adelante porque el sintoma natural es pesimo: sin
   clave, appsettings.json aporta el texto literal "${JWT_SECRET}" (.NET no
   expande esa sintaxis), la app arranca igual y recien al intentar loguearse
   devuelve 400 con "IDX10653: The encryption algorithm HS256 requires a key
   size of at least 128 bits". Nada en ese mensaje sugiere que falta una
   variable de entorno.
   --------------------------------------------------------------------------- */
if (string.IsNullOrWhiteSpace(jwtSettings.Secret)
    || jwtSettings.Secret.Contains("${")
    || Encoding.UTF8.GetByteCount(jwtSettings.Secret) < 32)
{
    throw new InvalidOperationException(
        "Falta la clave de firma de los tokens, o es demasiado corta (HS256 " +
        "necesita al menos 32 bytes).\n" +
        "Se toma de la variable de entorno Jwt__Secret. Los lanzadores " +
        "INICIAR_APP.bat e INICIAR_DEPLOY.bat la leen de " +
        "C:\\PILL-DF\\_secrets\\webapp_jwt.txt.\n" +
        "Para generar una:\n" +
        "  powershell -Command \"$b=New-Object byte[] 48;" +
        "[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b);" +
        "[Convert]::ToBase64String($b)|Set-Content 'C:\\PILL-DF\\_secrets\\webapp_jwt.txt' -NoNewline\"");
}
builder.Services.AddAuthentication(options =>
{
    options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
})
.AddJwtBearer(options =>
{
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidateAudience = true,
        ValidateLifetime = true,
        ValidateIssuerSigningKey = true,
        ValidIssuer = jwtSettings.Issuer,
        ValidAudience = jwtSettings.Audience,
        IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtSettings.Secret)),
        ClockSkew = TimeSpan.Zero
    };
});

builder.Services.AddAuthorization();

// CORS
var corsOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? new[] { "http://localhost:3000" };
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowFrontend", policy =>
    {
        policy.WithOrigins(corsOrigins)
              .AllowAnyHeader()
              .AllowAnyMethod()
              .AllowCredentials();
    });
});

// Swagger
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "DF Group - API de Integracion",
        Version = "v1",
        Description = "API para integracion de ventas de franquicias de DF Group",
        Contact = new OpenApiContact
        {
            Name = "DF Group IT",
            Email = "integraciones@dfgroup.com"
        }
    });

    // JWT Bearer security definition
    options.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = ParameterLocation.Header,
        Description = "JWT Authorization header. Ejemplo: 'Bearer {token}'"
    });

    // API Key security definition (para ingesta de franquicias)
    options.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Name = "X-API-KEY",
        Description = "API Key de la franquicia"
    });

    options.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "Bearer"
                }
            },
            Array.Empty<string>()
        }
    });

    options.EnableAnnotations();
});

// Health checks
builder.Services.AddHealthChecks()
    .AddCheck<DatabaseHealthCheck>("database");

var app = builder.Build();

// Configure the HTTP request pipeline
app.UseSerilogRequestLogging();

// Global exception handler
app.UseMiddleware<ExceptionHandlingMiddleware>();

// Swagger (enabled in all environments for demo)
app.UseSwagger();
app.UseSwaggerUI(options =>
{
    options.SwaggerEndpoint("/swagger/v1/swagger.json", "DF Group API v1");
    options.RoutePrefix = "swagger";
});

app.UseCors("AllowFrontend");

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();
app.MapHealthChecks("/health");

/* ---------------------------------------------------------------------------
   El frontend compilado se sirve desde la misma aplicacion.

   En desarrollo el front corre aparte en :3000 con Vite y proxya /api al 7100.
   Para que alguien lo vea desde otra maquina eso obliga a exponer dos puertos y
   a mantener el proxy; sirviendo el build desde aca queda UNA sola URL y un
   solo puerto.

   El fallback a index.html es lo que hace que /ventas/informe-grido funcione al
   recargar: sin eso el router de React nunca llega a ver la ruta, porque el
   servidor busca un archivo con ese nombre y devuelve 404.
   Se aplica solo si existe wwwroot: si no se compilo el front, la API sigue
   funcionando igual y la raiz lleva a Swagger.
   --------------------------------------------------------------------------- */
var wwwroot = Path.Combine(app.Environment.ContentRootPath, "wwwroot");
if (Directory.Exists(wwwroot) && File.Exists(Path.Combine(wwwroot, "index.html")))
{
    app.UseDefaultFiles();
    app.UseStaticFiles();

    // Cualquier ruta que no sea API, swagger ni health, la resuelve el router
    // del navegador.
    app.MapFallbackToFile("index.html");

    Log.Information("Frontend servido desde {Ruta}", wwwroot);
}
else
{
    // Sin build del front, la raiz lleva a la documentacion de la API.
    app.MapGet("/", () => Results.Redirect("/swagger"));
    Log.Warning("No hay frontend compilado en wwwroot: solo se expone la API.");
}

Log.Information("DF Group API iniciada en {Environment}", app.Environment.EnvironmentName);

app.Run();
