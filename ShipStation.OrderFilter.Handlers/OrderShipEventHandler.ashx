<%@ WebHandler Language="C#" Class="Ignia.ShipStation.OrderShipEventHandler" %>
/*==============================================================================================================================
| Author        Ignia, LLC
| Client        Ignia, LLC
| Project       ShipStation Order Ship Event Test
\=============================================================================================================================*/
using System;
using System.Collections.Specialized;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Web;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace Ignia.ShipStation {

  /*============================================================================================================================
  | CLASS: ORDER SHIP EVENT HANDLER
  \---------------------------------------------------------------------------------------------------------------------------*/
  public class OrderShipEventHandler : HttpTaskAsyncHandler {

    /*==========================================================================================================================
    | PRIVATE MEMBERS
    \-------------------------------------------------------------------------------------------------------------------------*/
    private     HttpRequest     _request;
    private     HttpResponse    _response;
    private     string          _shipStationBaseUrl             = "https://ssapi.shipstation.com";
    private     string          _shipStationApiKey              = Environment.GetEnvironmentVariable("ShipStationApiKey");
    private     string          _shipStationClientSecret        = Environment.GetEnvironmentVariable("ShipStationClientSecret");
    private     string          _logLocation                    = "";

    /*==========================================================================================================================
    | IS REUSABLE (REQUIRED)
    \-------------------------------------------------------------------------------------------------------------------------*/
    public bool IsReusable {
      get {
        return false;
      }
    }

    /*==========================================================================================================================
    | LOG LOCATION
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Defines the file location for the handler log.
    /// </summary>
    public string LogLocation {
      get {
        var timeZone            = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");
        var utcNow              = DateTime.UtcNow;
        var pacificNow          = TimeZoneInfo.ConvertTimeFromUtc(utcNow, timeZone);
        _logLocation            = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\..\LogFiles\Application\ShipStation\OrderShipEventHandlerLog_" + pacificNow.ToString("yyyyMMdd") + ".txt");
        // Ensure file exists
        if (!File.Exists(_logLocation)) {
          File.Create(_logLocation).Close();
        }
        return _logLocation;
      }
      set {
        _logLocation = value;
      }
    }

    /*==========================================================================================================================
    | HTTP CLIENT
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Instantiates the common HTTP client.
    /// </summary>
    public HttpClient HttpClient {
      get {

        /*----------------------------------------------------------------------------------------------------------------------
        | Configure HTTP client authorization
        \---------------------------------------------------------------------------------------------------------------------*/
        string clientCredentials = Convert.ToBase64String(ASCIIEncoding.ASCII.GetBytes(_shipStationApiKey + ":" + _shipStationClientSecret));

        /*----------------------------------------------------------------------------------------------------------------------
        | Configure HTTP client
        \---------------------------------------------------------------------------------------------------------------------*/
        var httpClient          = new HttpClient();
        httpClient.BaseAddress  = new Uri(_shipStationBaseUrl);
        httpClient.Timeout      = new TimeSpan(0, 5, 0);
        httpClient.DefaultRequestHeaders.TryAddWithoutValidation(
          "authorization",
          "Basic " + clientCredentials
        );

        /*----------------------------------------------------------------------------------------------------------------------
        | Return client
        \---------------------------------------------------------------------------------------------------------------------*/
        return httpClient;

      }
    }

    /*==========================================================================================================================
    | PROCESS ORDER FULFILLMENT EVENT REQUEST
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Manages incoming POST requests from the Shopify API webhook.
    /// </summary>
    /// <param name="context">The current HttpContext.</param>
    public override async Task ProcessRequestAsync(HttpContext context) {

      /*------------------------------------------------------------------------------------------------------------------------
      | Set HttpContext properties
      \-----------------------------------------------------------------------------------------------------------------------*/
      _request                  = context.Request;
      _response                 = context.Response;

      /*------------------------------------------------------------------------------------------------------------------------
      | Rewind the input stream (as it has already been read by the pipeline), then read it
      \-----------------------------------------------------------------------------------------------------------------------*/
      _request.InputStream.Position     = 0;
      var streamReader                  = new StreamReader(_request.InputStream);
      var postedData                    = streamReader.ReadToEnd();
      streamReader.Close();

      /*------------------------------------------------------------------------------------------------------------------------
      | Log HTTP request information
      \-----------------------------------------------------------------------------------------------------------------------*/
      await WriteApiRequestLog(_request, postedData);

      /*------------------------------------------------------------------------------------------------------------------------
      | End processing if request is not a POST
      \-----------------------------------------------------------------------------------------------------------------------*/
      if (_request.HttpMethod != "POST") {
        await WriteLog("Unexpected request method", _request.HttpMethod);
        return;
      }

      /*------------------------------------------------------------------------------------------------------------------------
      | Exit
      \-----------------------------------------------------------------------------------------------------------------------*/
      return;

    }

    /*==========================================================================================================================
    | WRITE API REQUEST LOG
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Writes incoming HTTPRequest variables and the ShipStation POST data to a text log.
    /// </summary>
    /// <param name="request">The incoming HttpRequest object.</param>
    /// <param name="inputStream">The body of the incoming HttpRequest.</param>
    private async Task WriteApiRequestLog(HttpRequest request, string inputStream) {

      /*------------------------------------------------------------------------------------------------------------------------
      | Establish log output, with request method
      \-----------------------------------------------------------------------------------------------------------------------*/
      string logOutput          = "   * Method: " + _request.HttpMethod;

      /*------------------------------------------------------------------------------------------------------------------------
      | Log request headers
      \-----------------------------------------------------------------------------------------------------------------------*/
      string requestHeaders     = "\r\n   * Request Headers: ";
      int keysLoop, valuesLoop;
      NameValueCollection headersCollection;
      headersCollection         = _request.Headers;
      String[] keysArray        = headersCollection.AllKeys;
      for (keysLoop = 0; keysLoop<keysArray.Length; keysLoop++) {
        requestHeaders         += "\r\n     - " + keysArray[keysLoop] + ": ";
        // Get all values under this key
        String[] valuesArray    = headersCollection.GetValues(keysArray[keysLoop]);
        for (valuesLoop = 0; valuesLoop<valuesArray.Length; valuesLoop++) {
          requestHeaders       += ((valuesArray[valuesLoop] != null)? valuesArray[valuesLoop].ToString() : "null");
        }
      }
      logOutput                += requestHeaders;

      /*------------------------------------------------------------------------------------------------------------------------
      | Add the HttpRequest body to the log output
      \-----------------------------------------------------------------------------------------------------------------------*/
      if (!String.IsNullOrEmpty(inputStream)) {
        logOutput              += "\r\n   * InputStream:\r\n     " + inputStream.ToString();
      }

      /*------------------------------------------------------------------------------------------------------------------------
      | Use current PST/PDT date/time for logging
      \-----------------------------------------------------------------------------------------------------------------------*/
      var timeZone              = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");
      var utcNow                = DateTime.UtcNow;
      var pacificNow            = TimeZoneInfo.ConvertTimeFromUtc(utcNow, timeZone);

      /*------------------------------------------------------------------------------------------------------------------------
      | Write log message to file
      \-----------------------------------------------------------------------------------------------------------------------*/
      using (StreamWriter streamWriter = File.AppendText(LogLocation)) {
        streamWriter.WriteLine("// ========================================================== //");
        streamWriter.Write("\r\n  HTTP Request Log: ");
        streamWriter.WriteLine("{0} {1}", pacificNow.ToLongTimeString(), pacificNow.ToLongDateString());
        streamWriter.WriteLine();
        streamWriter.WriteLine("{0}", logOutput);
        streamWriter.WriteLine();
      }

    }

    /*==========================================================================================================================
    | WRITE LOG
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Writes a log entry, using the provided log message.
    /// </summary>
    /// <param name="logHeading">The header/title to include with the log message.</param>
    /// <param name="logMessage">The message to write to the log.</param>
    private async Task WriteLog(string logHeading, string logMessage) {

      /*------------------------------------------------------------------------------------------------------------------------
      | Use current PST/PDT date/time for logging
      \-----------------------------------------------------------------------------------------------------------------------*/
      var timeZone              = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");
      var utcNow                = DateTime.UtcNow;
      var pacificNow            = TimeZoneInfo.ConvertTimeFromUtc(utcNow, timeZone);

      /*------------------------------------------------------------------------------------------------------------------------
      | Write log message to file
      \-----------------------------------------------------------------------------------------------------------------------*/
      using (StreamWriter streamWriter = File.AppendText(LogLocation)) {
        streamWriter.WriteLine("// ========================================================== //");
        streamWriter.Write("\r\n  " + logHeading + ": ");
        streamWriter.WriteLine("{0} {1}", pacificNow.ToLongTimeString(), pacificNow.ToLongDateString());
        streamWriter.WriteLine();
        streamWriter.WriteLine("  {0}", logMessage);
        streamWriter.WriteLine();
      }
    }

  } // Class
} // Namespace