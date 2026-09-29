using System.Net;
using System.Net.Mail;

namespace DFGroup.Api.Services;

/// <summary>Un mail a enviar, ya compuesto.</summary>
public record MailSalida(string Para, string Asunto, string CuerpoHtml, string? Copia = null);

/// <summary>Como salio cada envio. Nunca tira: el que llama decide que hacer.</summary>
public record MailResultado(string Para, bool Enviado, string? Error = null);

public interface IMailService
{
    /// <summary>False si falta configuracion: no tiene sentido intentar.</summary>
    bool Configurado { get; }

    Task<MailResultado> EnviarAsync(MailSalida mail, CancellationToken ct = default);
}

/// <summary>
/// Envio de correo por SMTP.
/// </summary>
/// <remarks>
/// LA CLAVE NO VIVE EN appsettings.json
/// ------------------------------------
/// Ese archivo viaja al repositorio, que es publico. La clave se lee de la
/// variable de entorno Smtp__Password, que los lanzadores toman de
/// C:\PILL-DF\_secrets\webapp_smtp.txt, igual que se hace con la de firma de
/// los tokens.
///
/// Es una CONTRASENA DE APLICACION de Gmail, de 16 caracteres, no la clave de
/// la cuenta. Se genera en https://myaccount.google.com/apppasswords y hace
/// falta tener la verificacion en 2 pasos activada. Si el 2FA se desactiva,
/// Google la revoca de forma permanente y volver a activarlo NO la restaura:
/// hay que generar una nueva.
///
/// UN CLIENTE POR ENVIO
/// --------------------
/// SmtpClient no es reutilizable entre envios concurrentes, y la cantidad de
/// mails aca es de a cuatro por vez. Abrir y cerrar la conexion cada vez sale
/// mas barato que razonar sobre un cliente compartido.
/// </remarks>
public class MailService : IMailService
{
    private readonly ILogger<MailService> _log;
    private readonly string _servidor;
    private readonly int _puerto;
    private readonly string _remitente;
    private readonly string _usuario;
    private readonly string _clave;
    private readonly string _nombreRemitente;

    public MailService(IConfiguration config, ILogger<MailService> log)
    {
        _log = log;
        var s = config.GetSection("Smtp");
        _servidor = s["Host"] ?? "smtp.gmail.com";
        _puerto = int.TryParse(s["Port"], out var p) ? p : 587;
        _remitente = s["From"] ?? string.Empty;
        // Si no se indica usuario, se usa el remitente: es el caso de Gmail.
        _usuario = string.IsNullOrWhiteSpace(s["User"]) ? _remitente : s["User"]!;
        _nombreRemitente = s["FromName"] ?? "DF Group";
        // Gmail muestra la clave de aplicacion separada en grupos de cuatro y
        // se pega tal cual: los espacios no forman parte de la clave. Se saca
        // ademas cualquier caracter invisible, que es como se cuela un BOM o
        // un salto de linea cuando la clave pasa por un archivo de texto.
        _clave = new string((s["Password"] ?? string.Empty)
            .Where(c => !char.IsWhiteSpace(c) && !char.IsControl(c) && c != '﻿')
            .ToArray());
    }

    public bool Configurado =>
        !string.IsNullOrWhiteSpace(_remitente) && !string.IsNullOrWhiteSpace(_clave);

    public async Task<MailResultado> EnviarAsync(MailSalida mail, CancellationToken ct = default)
    {
        if (!Configurado)
        {
            return new MailResultado(mail.Para, false,
                "Falta configurar el correo saliente (Smtp:From y la variable Smtp__Password).");
        }

        try
        {
            using var cliente = new SmtpClient(_servidor, _puerto)
            {
                EnableSsl = true,
                DeliveryMethod = SmtpDeliveryMethod.Network,
                UseDefaultCredentials = false,
                Credentials = new NetworkCredential(_usuario, _clave),
                Timeout = 30_000,
            };

            using var msg = new MailMessage
            {
                From = new MailAddress(_remitente, _nombreRemitente),
                Subject = mail.Asunto,
                Body = mail.CuerpoHtml,
                IsBodyHtml = true,
            };
            msg.To.Add(mail.Para);
            if (!string.IsNullOrWhiteSpace(mail.Copia)) msg.CC.Add(mail.Copia);

            await cliente.SendMailAsync(msg, ct);
            _log.LogInformation("Mail enviado a {Para}: {Asunto}", mail.Para, mail.Asunto);
            return new MailResultado(mail.Para, true);
        }
        catch (Exception ex)
        {
            // Un destinatario que falla no puede tumbar al resto del lote, asi
            // que el error vuelve como dato y no como excepcion.
            _log.LogError(ex, "Fallo el mail a {Para}", mail.Para);
            return new MailResultado(mail.Para, false, ex.Message);
        }
    }
}
