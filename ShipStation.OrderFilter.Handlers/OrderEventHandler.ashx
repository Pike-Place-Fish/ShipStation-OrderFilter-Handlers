<%@ WebHandler Language="C#" Class="Ignia.ShipStation.OrderEventHandler" %>
/*==============================================================================================================================
| Author        Ignia, LLC
| Client        Ignia, LLC
| Project       ShipStation Order Filter
\=============================================================================================================================*/
using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace Ignia.ShipStation {

  /*============================================================================================================================
  | CLASS: ORDER EVENT HANDLER
  \---------------------------------------------------------------------------------------------------------------------------*/
  public class OrderEventHandler : HttpTaskAsyncHandler {

    /*==========================================================================================================================
    | PRIVATE MEMBERS
    \-------------------------------------------------------------------------------------------------------------------------*/
    private     HttpRequest     _request;
    private     HttpResponse    _response;
    private     string          _logLocation                    = "";
    private     string          _ordersToUpdate                 = "";
    private     string          _modifiedOrders                 = "";
    private     string          _nonModifiedOrders              = "";
    private     string          _shipStationApiKey              = Environment.GetEnvironmentVariable("ShipStationApiKey");
    private     string          _shipStationClientSecret        = Environment.GetEnvironmentVariable("ShipStationClientSecret");
    private     static          readonly        object          _syncRoot       = new object();


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
        _logLocation            = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\..\LogFiles\Application\ShipStation\OrderEventHandlerLog_" + pacificNow.ToString("yyyyMMdd") + ".txt");
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
        httpClient.BaseAddress  = new Uri("https://ssapi.shipstation.com");
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
    | PROCESS ORDER EVENT REQUEST
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Manages incoming POST requests from the ShipStation API webhook.
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
      | Set up ShipStation API resource_url call
      \-----------------------------------------------------------------------------------------------------------------------*/
      string resourceUrl        = "";
      string resourceResponse   = "";
      ExceptionDispatchInfo capturedException   = null;
      try {
        dynamic payload         = JObject.Parse(postedData);

        if (payload != null && payload.resource_url != null) {
          resourceUrl           = payload.resource_url;
        }

        // Confirm the resource_url is a ShipStation API URL
        if (!Regex.IsMatch(resourceUrl, @"ssapi(?:\d{1}|).shipstation.com", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Multiline)) {
          await WriteLog("Invalid API URL sent", resourceUrl);
          return;
        }

      }
      catch(FormatException ex) {
        capturedException       = ExceptionDispatchInfo.Capture(ex);
      }
      if (capturedException != null) {
        await WriteLog("ShipStation POST parse error", capturedException.SourceException.Message);
        capturedException       = null;
      }

      /*------------------------------------------------------------------------------------------------------------------------
      | Retrieve the response from the ShipStation API's resource_url
      \-----------------------------------------------------------------------------------------------------------------------*/
      if (String.IsNullOrEmpty(resourceUrl)) {
        await WriteLog("ShipStation POST resource URL error", "Resource URL not available.");
        return;
      }

      // GET the (presumably) orders response from the resource_url
      Task<string> apiResult    = GetApiResourceAsync(resourceUrl);
      resourceResponse          = await apiResult;

      // If response is unavailable, exit
      if (String.IsNullOrEmpty(resourceResponse)) {
        await WriteLog("ShipStation Orders response error", "Response body not available.");
        return;
      }

      // Log the response
      await WriteLog("GET resource_url response", resourceResponse);

      /*------------------------------------------------------------------------------------------------------------------------
      | Send orders through ModifyOrdersAsync for processing and assembling the multiple orders update JSON string
      \-----------------------------------------------------------------------------------------------------------------------*/
      try {

        string updateResponse           = "";
        dynamic openOrders              = JObject.Parse(resourceResponse);

        // Exit if the resource_url response does not contain order(s) information
        if (openOrders == null || openOrders.orders == null || openOrders.orders.Count < 1) {
          await WriteLog("ShipStation Orders response error", "Orders not available in response.");
          return;
        }

        // POST the assembled modified orders to the /orders/createorders endpoint
        var modifiedOrdersResult        = await ModifyOrdersAsync(openOrders.orders);
        if (!String.IsNullOrEmpty(modifiedOrdersResult) && modifiedOrdersResult != "[]") {

          await WriteLog("Orders to update", modifiedOrdersResult);
          var content                   = new StringContent(modifiedOrdersResult, System.Text.Encoding.UTF8, "application/json");

          using (HttpClient) {
            using (content) {
              using (var response = await HttpClient.PostAsync("orders/createorders", content)) {
                response.Version        = HttpVersion.Version10; //.Version11?
                updateResponse          = await response.Content.ReadAsStringAsync();
                if (!String.IsNullOrEmpty(updateResponse)) {
                  await WriteLog("Modify Order POST response", updateResponse);
                }
              }
            }
          }

        }

      }
      catch(FormatException formatException) {
        capturedException       = ExceptionDispatchInfo.Capture(formatException);
      }
      catch (Exception exception) {
        capturedException       = ExceptionDispatchInfo.Capture(exception);
      }
      finally {
      }

      // Log the modified and non-modified orders
      if (!String.IsNullOrEmpty(_modifiedOrders)) {
        await WriteLog("Modified Order(s)", _modifiedOrders.TrimEnd(',', ' '));
      }
      if (!String.IsNullOrEmpty(_nonModifiedOrders)) {
        await WriteLog("Non-modified Order(s)", _nonModifiedOrders.TrimEnd(',', ' '));
      }

      // Log any exceptions
      if (capturedException != null) {
        await WriteLog(
          "Error updating orders via createorders endpoint",
          capturedException.SourceException.Message + " - Stack trace: " + capturedException.SourceException.StackTrace
        );
        capturedException       = null;
      }

      /*------------------------------------------------------------------------------------------------------------------------
      | Exit
      \-----------------------------------------------------------------------------------------------------------------------*/
      return;

    }

    /*==========================================================================================================================
    | GET API RESOURCE
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Retrieves the JSON response from the requested resource URL (which should be sent by the ShipStation webhook).
    /// </summary>
    /// <param name="resourceUrl">The resource (API endpoint) to call.</param>
    /// <returns>A JSON response from the ShipStation API, based on the GET request to the resource URL.</returns>
    private async Task<string> GetApiResourceAsync(string resourceUrl) {
      string apiResult          = "";
      using (HttpClient) {
        using (var response = await HttpClient.GetAsync(resourceUrl)) {
          apiResult             = await response.Content.ReadAsStringAsync();
        }
      }
      return apiResult;
    }

    /*==========================================================================================================================
    | MODIFY ORDERS
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Loops through the received orders object, modifying each order, then adding the order to the full orders (to modify)
    ///   JSON string for use with ShipStation's
    ///   <see href="http://www.shipstation.com/developer-api/#/reference/orders/createupdate-multiple-orders" />
    ///   Create/Update Multiple Orders API endpoint</see>.
    /// </summary>
    /// <param name="ordersToModify">The dynamic Orders object as returned from the API's resource_url call.</param>
    /// <returns>JSON string</returns>
    private async Task<string> ModifyOrdersAsync(dynamic orders) {

      /*------------------------------------------------------------------------------------------------------------------------
      | Start clock to verify execution time
      \-----------------------------------------------------------------------------------------------------------------------*/
      Stopwatch stopwatch       = new Stopwatch();
      stopwatch.Start();

      /*------------------------------------------------------------------------------------------------------------------------
      | Loop through each order, modify it, and add it to the orders JSON
      \-----------------------------------------------------------------------------------------------------------------------*/
      StringBuilder ordersJSON  = new StringBuilder("[");
      foreach (dynamic order in orders) {

        /*----------------------------------------------------------------------------------------------------------------------
        | Set the order initially to not needing processing, to then be flagged depending on the state of the the items 
        \---------------------------------------------------------------------------------------------------------------------*/
        bool processOrder       = false;

        /*----------------------------------------------------------------------------------------------------------------------
        | Reserve isGift so "gift" property may be set once items are processed
        \---------------------------------------------------------------------------------------------------------------------*/
        bool isGift             = false;
        if (
          (order.gift != null && Convert.ToBoolean(order.gift)) ||
          (order.billTo.name.ToString().ToLower() != order.shipTo.name.ToString().ToLower())
        ) {
          isGift                = true;
        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Specifically set carrier code
        \---------------------------------------------------------------------------------------------------------------------*/
        order.carrierCode       = "ups";

        /*----------------------------------------------------------------------------------------------------------------------
        | Add modified order properties based on customerNotes: requestedShippingService, serviceCode, shippingAmount,
        | shipByDate, packageCode, dimensions (units, length, width, height), and giftMessage
        \---------------------------------------------------------------------------------------------------------------------*/
        string customerNotes    = "";
        string internalNotes    = "";
        string serviceCode      = "ups_next_day_air";
        string carrierService   = "";
        string packageType      = "Standard Shipper";
        string shippingAmount   = "";
        string shipByDate       = "";
        string shippingService  = "";
        double weightToAdd      = 0.00;
        double length           = 16;
        double width            = 11;
        double height           = 3;
        string packageCode      = "package";

        /*----------------------------------------------------------------------------------------------------------------------
        | Set variables for carrier service and packaging type
        \---------------------------------------------------------------------------------------------------------------------*/
        if (order.requestedShippingService != null) {
          shippingService       = order.requestedShippingService;
          string serviceLowered = shippingService.ToLower();

          // Check for USPS orders
          if (serviceLowered.IndexOf("usps") >= 0) {
            order.carrierCode   = "stamps_com";
            serviceCode         = "usps_first_class_mail";
            length              = 10;
            width               = 6;
            height              = 0.5;
            packageType         = "USPS Letter";
          }

          // Otherwise, match against UPS options
          else if (serviceLowered.IndexOf("next day air early") >= 0) {
            serviceCode         = "ups_next_day_air_early_am";
          }
          else if (serviceLowered.IndexOf("next day air saver") >= 0) {
            serviceCode         = "ups_next_day_air_saver";
          }
          else if (serviceLowered.IndexOf("2nd day air am") >= 0) {
            serviceCode         = "ups_2nd_day_air_am";
          }
          else if (serviceLowered.IndexOf("2nd day") >= 0) {
            serviceCode         = "ups_2nd_day_air";
          }
          else if (serviceLowered.IndexOf("3 day") >= 0) {
            serviceCode         = "ups_3_day_select";
          }
          else if (serviceLowered.IndexOf("ground") >= 0) {
            serviceCode         = "ups_ground";
          }

          // Set package type for small or large packages
          if (serviceLowered.IndexOf("sm pkg") >= 0) {
            length              = 15;
            width               = 12;
            height              = 11;
            packageType         = "Small Shipper";
          }
          else if (serviceLowered.IndexOf("lg pkg") >= 0) {
            length              = 32;
            width               = 10;
            height              = 13;
            packageType         = "Large Shipper";
          }

        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Set Custom Field 1 based on requested shipping service
        \---------------------------------------------------------------------------------------------------------------------*/
        order.advancedOptions.customField1      = packageType;

        /*----------------------------------------------------------------------------------------------------------------------
        | Specifically set serviceCode, if it's not already available
        \---------------------------------------------------------------------------------------------------------------------*/
        if (order.serviceCode == null) {
          order.serviceCode = serviceCode;
        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Specifically set package dimensions, if they are not already available
        \---------------------------------------------------------------------------------------------------------------------*/
        JObject dimensions      = new JObject();
        dimensions.Add("units", "inches");
        dimensions.Add("length", length);
        dimensions.Add("width", width);
        dimensions.Add("height", height);
        if (order.dimensions == null) {
          order.dimensions      = JToken.FromObject(dimensions);
        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Specifically set package code, if not already available
        \---------------------------------------------------------------------------------------------------------------------*/
        if (order.packageCode == null) {
          order.packageCode = "package";
        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Calculate weight to add to total, if applicable, based on shipping service packaging
        \---------------------------------------------------------------------------------------------------------------------*/
        if (!String.IsNullOrEmpty(shippingService)) {
          weightToAdd           = await CalculatePackagingWeight(shippingService);
        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Convert customer notes items to Dictionary, accounting for POS note with empty "key", then process accordingly
        \---------------------------------------------------------------------------------------------------------------------*/
        if (order.customerNotes != null) {

          customerNotes         = order.customerNotes;
          Dictionary<string, string> notesDictionary    = new Dictionary<string, string>();
          string[] allowedKeys  = new string[] { "date", "shipDay", "giftMessage", "isGift" };
          string[] noteItems    = customerNotes.Split(new string[] { "<br/>", "\u003cbr/\u003e" }, StringSplitOptions.RemoveEmptyEntries);
          string firstNote      = "";
          string firstNoteKey   = "";

          // Check for website orders where internalNotes is just "Notes: isGift: on"
          if (order.internalNotes == "Notes: isGift: on") {
            order.gift          = true;
            order.internalNotes = " ";
          }

          // Check first note for empty "key" (coming from POS); if present, add "Notes" key.
          if (noteItems.Length > 0) {
            firstNote           = noteItems[0];
            if (!String.IsNullOrEmpty(firstNote)) {
              if (firstNote.IndexOf(": ") <= 0) {
                noteItems[0]    = "Notes: " + firstNote;
              }
              // Otherwise, make sure it's in the keys whitelist; if not, again, prefix with "Notes" key.
              else {
                firstNoteKey    = firstNote.Substring(0, firstNote.IndexOf(":"));
                if (!firstNoteKey.StartsWith("_") && !allowedKeys.Contains(firstNoteKey)) {
                  noteItems[0]  = "Notes: " + firstNote;
                }
              }
            }
          }

          // Add each of the notes to the Dictionary (with potentially modified first note)
          foreach (string noteItem in noteItems) {
            int delimiter       = noteItem.IndexOf(": ");
            string noteKey      = noteItem.Substring(0, delimiter);
            string noteValue    = noteItem.Substring(delimiter+2);
            notesDictionary.Add(noteKey, noteValue);
          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Set requestedShippingService, serviceCode, dimensions values, and added weight, based on _carrierService value
          \-------------------------------------------------------------------------------------------------------------------*/
          if (notesDictionary.ContainsKey("_carrierService")) {
            carrierService      = notesDictionary["_carrierService"];
            serviceCode         = carrierService.Substring(0, carrierService.IndexOf(" (")).ToLower().Replace(" ", "_").Replace(".", "");

            // Handle free/included shipping service
            if (carrierService.ToLower().IndexOf("free") >= 0) {
              serviceCode       = "ups_next_day_air";
            }

            // Set requestedShippingService, if it's not already available
            if (order.requestedShippingService == null || order.requestedShippingService == "In store shipping") {
              order.requestedShippingService    = carrierService;
            }

            // Set customField1 based on requested service
            if (carrierService.ToLower().IndexOf("sm pkg") >= 0) {
              packageType       = "Small Shipper";
            }
            else if (carrierService.ToLower().IndexOf("lg pkg") >= 0) {
              packageType       = "Large Shipper";
            }
            order.advancedOptions.customField1  = packageType;

            // Set added weight, if applicable, based on packaging
            if (!String.IsNullOrEmpty(carrierService)) {
              weightToAdd       = await CalculatePackagingWeight(carrierService);
            }

            // Set serviceCode, if it's not already available
            if (order.serviceCode == null) {
              order.serviceCode = serviceCode;
            }

            // Determine dimemnsions for package (default to non-perishable/standard package)
            length       = 16;
            width        = 11;
            height       = 3;
            packageCode  = "standard_package";
            if (carrierService.ToLower().IndexOf("sm pkg") >= 0) {
              length            = 15;
              width             = 12;
              height            = 11;
              packageCode       = "small_shipper";
              packageType       = "Small Shipper";
            }
            else if (carrierService.ToLower().IndexOf("lg pkg") >= 0) {
              length            = 32;
              width             = 10;
              height            = 13;
              packageCode       = "large_shipper";
              packageType       = "Large Shipper";
            }
            else if (carrierService.ToLower().IndexOf("usps") >= 0) {
              length            = 10;
              width             = 6;
              height            = 0.5;
              packageCode       = "letter";
              packageType       = "Letter";
            }
            JObject posDimensions  = new JObject();
            posDimensions.Add("units", "inches");
            posDimensions.Add("length", length);
            posDimensions.Add("width", width);
            posDimensions.Add("height", height);
            if (order.dimensions == null) {
              order.dimensions  = JToken.FromObject(posDimensions);
            }
            // order.Add("packageCode", "package");

            // Remove the _carrierService note from the notes dictionary
            notesDictionary.Remove("_carrierService");

          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Set shippingAmount
          \-------------------------------------------------------------------------------------------------------------------*/
          if (notesDictionary.ContainsKey("_shippingAmount")) {
            shippingAmount              = notesDictionary["_shippingAmount"];
            order.shippingAmount        = Convert.ToDouble(shippingAmount);
            // Remove the _shippingAmount note from the notes dictionary
            notesDictionary.Remove("_shippingAmount");
          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Set shipByDate and saturdayDelivery, if applicable
          \-------------------------------------------------------------------------------------------------------------------*/
          if (notesDictionary.ContainsKey("date")) {
            shipByDate          = notesDictionary["date"];
            DateTime shipDay    = DateTime.Parse(shipByDate);
            // Set shipByDate
            order.shipByDate    = shipByDate;
            // Set saturdayDelivery, if applicable
            if (shipDay.ToString("dddd") == "Friday" && serviceCode.IndexOf("next_day") >= 0) {
              order.advancedOptions.saturdayDelivery    = true;
            }
            // Remove the AutoTag date note from the notes dictionary
            notesDictionary.Remove("date");
          }
          if (notesDictionary.ContainsKey("shipDay")) {
            notesDictionary.Remove("shipDay");
          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Update shipTo object/properties if _shipToName property is available
          \-------------------------------------------------------------------------------------------------------------------*/
          if (notesDictionary.ContainsKey("_shippingAddressIndex")) {
            notesDictionary.Remove("_shippingAddressIndex");
          }
          if (notesDictionary.ContainsKey("_shipToName")) {
            order.shipTo.name           = notesDictionary["_shipToName"];
            notesDictionary.Remove("_shipToName");
            if (notesDictionary.ContainsKey("_shipToCompany")) {
              order.shipTo.company      = notesDictionary["_shipToCompany"];
              order.shipTo.residential  = false;
              notesDictionary.Remove("_shipToCompany");
            }
            else {
              order.shipTo.company      = "";
              order.shipTo.residential  = true;
            }
            order.shipTo.street1        = notesDictionary["_shipToAddress1"];
            notesDictionary.Remove("_shipToAddress1");
            if (notesDictionary.ContainsKey("_shipToAddress2")) {
              order.shipTo.street2      = notesDictionary["_shipToAddress2"];
              notesDictionary.Remove("_shipToAddress2");
            }
            order.shipTo.city           = notesDictionary["_shipToCity"];
            notesDictionary.Remove("_shipToCity");
            order.shipTo.state          = notesDictionary["_shipToState"];
            notesDictionary.Remove("_shipToState");
            order.shipTo.postalCode     = notesDictionary["_shipToZip"];
            notesDictionary.Remove("_shipToZip");
            order.shipTo.country        = notesDictionary["_shipToCountry"];
            notesDictionary.Remove("_shipToCountry");
            if (notesDictionary.ContainsKey("_shipToPhone")) {
              order.shipTo.phone        = notesDictionary["_shipToPhone"];
              notesDictionary.Remove("_shipToPhone");
            }
          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Update gift settings
          \-------------------------------------------------------------------------------------------------------------------*/
          if (notesDictionary.ContainsKey("giftMessage") || notesDictionary.ContainsKey("isGift")) {
            isGift                      = true;
            if (notesDictionary.ContainsKey("giftMessage")) {
              if (String.IsNullOrEmpty(order.giftMessage.ToString())) {
                order.giftMessage       = notesDictionary["giftMessage"];
              }
              // Remove the giftMessage note from the notes dictionary
              notesDictionary.Remove("giftMessage");
            }
            if (notesDictionary.ContainsKey("isGift")) {
              // Remove the giftMessage note from the notes dictionary
              notesDictionary.Remove("isGift");
            }
          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Move remaining customerNotes to internalNotes
          \-------------------------------------------------------------------------------------------------------------------*/
          if (customerNotes != " ") {
            internalNotes       = string.Join("<br/> - ", notesDictionary.Select(x => x.Key + ": " + x.Value));
            order.internalNotes = internalNotes;
          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Empty customerNotes
          \-------------------------------------------------------------------------------------------------------------------*/
          order.customerNotes = " ";
          //order.Property("customerNotes").Remove();

        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Add modified items (with any "Shipping", "Gift Order", or "Perishable Items" items removed)
        \---------------------------------------------------------------------------------------------------------------------*/
        JArray items            = new JArray();
        double itemsWeight      = 0.00;
        for (int i=0; i<order.items.Count; i++) {
          var item              = order.items[i];
          double itemWeight     = 0.00;
          bool useCustomWeight  = false;

          /*--------------------------------------------------------------------------------------------------------------------
          | Modify item options
          \-------------------------------------------------------------------------------------------------------------------*/
          JArray options                = new JArray();

          for (int o=0; o<item.options.Count; o++) {
            var option                  = item.options[o];
            string optionName           = option.name.ToString();
            string optionValue          = option.value.ToString();

            // Set item weight based on custom weight option value
            if (optionName.ToLower().Equals("weight")) {
              string weightValue        = optionValue.Substring(0, optionValue.IndexOf(" lbs"));
              double weightInLbs        = Convert.ToDouble(weightValue);
              double weightInOz         = (weightInLbs*16);
              double initialQuantity    = Convert.ToDouble(item.quantity);
              double pricePerPound      = item.unitPrice;
              useCustomWeight           = true;
              item.weight.value         = weightInOz;
              itemWeight                = weightInOz;

              // Set item quantity to 1 and update unitPrice to account for weight adjustment
              item.unitPrice            = (initialQuantity*pricePerPound);
              item.quantity             = 1;

              // Keep the option for display on the packing slip
              if (!String.IsNullOrEmpty(weightValue)) {
                options.Add(option);
              }
            }

            // Rename cutting and special instructions options
            else if (optionName.ToLower().IndexOf("instructions") >= 0) {
              string newName            = await ConvertCamelToTitle(optionName);
              option.name               = newName;
              if (!String.IsNullOrEmpty(optionValue)) {
                options.Add(option);
              }
            }

            // If there are still internal item properties, flag the order as needing to be processed 
            else if (optionName.StartsWith("_")) {
              processOrder              = true;
            }

            // If the option does not meet any of the above conditions, and does not start with an underscore, add it as-is
            else {
              options.Add(option);
            }

          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Add total (per quantity) item weight to total itemsWeight
          \-------------------------------------------------------------------------------------------------------------------*/
          int? itemQuantity     = item.quantity;

          // If the item is not a custom weight item, calculate its weight based on the weight.value and quantity properties
          if (item.weight != null && item.weight.value != null && itemQuantity != null && !useCustomWeight) {
            itemWeight          = (itemQuantity*(Convert.ToDouble((item.weight.value).ToString())));
          }

          itemsWeight          += itemWeight;

          /*--------------------------------------------------------------------------------------------------------------------
          | Update gift settings based on gift order product (only applies to POS orders)
          \-------------------------------------------------------------------------------------------------------------------*/
          bool hasGiftOrderProduct      = (item.name.ToString().ToLower().IndexOf("gift order") >= 0 || item.sku.ToString().ToLower().IndexOf("gft999") >= 0);
          if (hasGiftOrderProduct || (order.gift == true && !String.IsNullOrEmpty(order.giftMessage.ToString()))) {
            isGift                      = true;

            if (!String.IsNullOrEmpty(internalNotes) || !String.IsNullOrEmpty(order.internalNotes.ToString())) {
              if (String.IsNullOrEmpty(internalNotes)) {
                internalNotes           = order.internalNotes.ToString();
              }
              string giftNote           = "";
              // If coming from the POS, double-check there aren't additional notes that have been moved to internal notes
              if (internalNotes.IndexOf("Notes:") >= 0 && internalNotes.IndexOf("<br/>") >= 0) {
                giftNote                = internalNotes.Substring(internalNotes.IndexOf("Notes: ")+7, internalNotes.IndexOf("<br/>"));
              }
              else if (internalNotes.IndexOf("Notes:") >= 0) {
                giftNote                = internalNotes.Substring(internalNotes.IndexOf("Notes: ")+7);
              }
              else {
                giftNote                = internalNotes;
              }
              if (!String.IsNullOrEmpty(giftNote) && !giftNote.StartsWith("_")) {
                order.giftMessage       = giftNote;
              }
              // Remove gift message from notes
              if (internalNotes == "Notes: " + giftNote + "<br/>" || internalNotes == "Notes: " + giftNote) {
              //order.internalNotes     = " ";
              }
            }
          }

          /*--------------------------------------------------------------------------------------------------------------------
          | Add item to modified items object
          \-------------------------------------------------------------------------------------------------------------------*/
          string itemName       = item.name.ToString().ToLower();
          string itemSku        = item.sku.ToString().ToLower();
          bool addItem          = (itemName.IndexOf("shipping") < 0 && itemSku.IndexOf("shp") < 0 &&
                                   itemName.IndexOf("gift order") < 0 && itemSku.IndexOf("gft999") < 0 &&
                                   itemName.IndexOf("perishable items") < 0 && itemSku.IndexOf("prs999") < 0);
          if (addItem) {
            item.options        = options;
            items.Add(item);
          }

        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Update order with modified items
        \---------------------------------------------------------------------------------------------------------------------*/
        order.items             = JToken.FromObject(items);

        /*----------------------------------------------------------------------------------------------------------------------
        | If there is weight to add (given packaging or custom weight items), adjust the total weight
        \---------------------------------------------------------------------------------------------------------------------*/
        double currentWeight    = 0.00;
        if (order.weight.value != null) {
          currentWeight         = Convert.ToDouble(order.weight.value);
        }

        await WriteLog(
          "Order #" + order.orderNumber.ToString() + " weight adjustment needed?",
          currentWeight.ToString() + " < (" + itemsWeight.ToString() + " + " + weightToAdd.ToString() + ") = " + (currentWeight < (itemsWeight+weightToAdd)).ToString()
        );

        if (weightToAdd > 0 && itemsWeight > 0 && currentWeight > 0) {
          if (currentWeight < (itemsWeight+weightToAdd)) {
            // Flag order as needing to be processed, and adjust the weight
            processOrder        = true;
            order.weight.value  = (itemsWeight + weightToAdd);
          }
        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Set order "gift" property based on isGift status
        \---------------------------------------------------------------------------------------------------------------------*/
        if (isGift) {
          order.gift            = true;
        }

        /*----------------------------------------------------------------------------------------------------------------------
        | Add processing log to Custom Field 3

        string customField3     = order.advancedOptions.customField3.ToString();
        if (customField3 == null || customField3.IndexOf("Processed") < 0) {
          // Flag the order as needing to be processed
          processOrder          = true;

          // Use current PST/PDT date/time for logging
          var timeZone          = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");
          var utcNow            = DateTime.UtcNow;
          var pacificNow        = TimeZoneInfo.ConvertTimeFromUtc(utcNow, timeZone);

          order.advancedOptions.customField3  += " - Processed by Order Filter: " + pacificNow.ToLongTimeString() + " " + pacificNow.ToShortDateString() + ". ";
        }

        \---------------------------------------------------------------------------------------------------------------------*/
        order.advancedOptions.customField3 = " ";

        if (processOrder) {

          /*--------------------------------------------------------------------------------------------------------------------
          | Add the order (number and ID) to the _modifiedOrders string
          \-------------------------------------------------------------------------------------------------------------------*/
          _modifiedOrders      += "#" + order.orderNumber + " (" + order.orderId + "), ";

          /*--------------------------------------------------------------------------------------------------------------------
          | Re-serialize the modified order object and append it to the orders JSON string builder
          \-------------------------------------------------------------------------------------------------------------------*/
          string orderContent                       = "";
          JsonSerializerSettings serializerSettings = new JsonSerializerSettings();
          serializerSettings.StringEscapeHandling   = StringEscapeHandling.EscapeHtml;
          orderContent                              = JsonConvert.SerializeObject(order, serializerSettings).Replace("&quot;", "\"");
          ordersJSON.Append(orderContent);
          ordersJSON.Append(",");

          /*--------------------------------------------------------------------------------------------------------------------
          | Log the JSON to be POSTed
          \-------------------------------------------------------------------------------------------------------------------*/
          await WriteLog("Modified Order JSON", orderContent);

        }

        else {

          /*--------------------------------------------------------------------------------------------------------------------
          | Add the order (number and ID) to the _nonModifiedOrders string
          \-------------------------------------------------------------------------------------------------------------------*/
          _nonModifiedOrders   += "#" + order.orderNumber + " (" + order.orderId + "), ";

        }

      }

      /*------------------------------------------------------------------------------------------------------------------------
      | Finalize the ordersJSON string
      \-----------------------------------------------------------------------------------------------------------------------*/
      string ordersPOST         = ordersJSON.ToString().TrimEnd(',') + "]";

      /*------------------------------------------------------------------------------------------------------------------------
      | Stop the clock and log the execution time
      \-----------------------------------------------------------------------------------------------------------------------*/
      stopwatch.Stop();
      await WriteLog("ModifyOrdersAsync execution time", stopwatch.Elapsed.ToString());

      /*------------------------------------------------------------------------------------------------------------------------
      | Return the assembled orders JSON
      \-----------------------------------------------------------------------------------------------------------------------*/
      return ordersPOST;

    }

    /*==========================================================================================================================
    | CALCULATE PACKAGING WEIGHT
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Determines what weight (in ounces) to add to the overall order weight, based on the packaging type and number of
    ///   packages.
    /// </summary>
    /// <param name="shippingService">The requested shipping service, including package type and number of packages.</param>
    private async Task<double> CalculatePackagingWeight(string shippingService) {

      double packagingWeight    = 0.00;

      if (String.IsNullOrEmpty(shippingService)) {
        return packagingWeight;
      }
      else {
        shippingService         = shippingService.ToLower();
      }

      if (shippingService.IndexOf("1 sm pkg") >= 0) {
        packagingWeight         = 128.00;
      }
      if (shippingService.IndexOf("1 lg pkg") >= 0) {
        packagingWeight         = 160.00;
      }
      if (shippingService.IndexOf("2 lg pkg") >= 0) {
        packagingWeight         = 320.00;
      }
      if (shippingService.IndexOf("3 lg pkg") >= 0) {
        packagingWeight         = 480.00;
      }
      if (shippingService.IndexOf("4 lg pkg") >= 0) {
        packagingWeight         = 640.00;
      }
      if (shippingService.IndexOf("5 lg pkg") >= 0) {
        packagingWeight         = 800.00;
      }
      if (shippingService.IndexOf("1 std pkg") >= 0) {
        packagingWeight         = 8.00;
      }
      if (shippingService.IndexOf("2 std pkg") >= 0) {
        packagingWeight         = 16.00;
      }
      if (shippingService.IndexOf("3 std pkg") >= 0) {
        packagingWeight         = 24.00;
      }
      if (shippingService.IndexOf("4 std pkg") >= 0) {
        packagingWeight         = 32.00;
      }
      if (shippingService.IndexOf("5 std pkg") >= 0) {
        packagingWeight         = 40.00;
      }
      if (shippingService.IndexOf("usps") >= 0) {
        packagingWeight         = 1.00;
      }

      return packagingWeight;

    }

    /*==========================================================================================================================
    | CONVERT CAMEL TO TITLE
    \-------------------------------------------------------------------------------------------------------------------------*/
    /// <summary>
    ///   Updates a camel-cased property/variable name to a human-readable title.
    /// </summary>
    /// <param name="propertyName">The property/variable name to convert.</param>
    /// <returns>The converted property/varible name.</returns>
    private async Task<string> ConvertCamelToTitle(string propertyName) {
      string title              = propertyName;
      TextInfo textInfo         = new CultureInfo("en-US", false).TextInfo;

      /*------------------------------------------------------------------------------------------------------------------------
      | Remove leading underscore, if needed (unexpected)
      \-----------------------------------------------------------------------------------------------------------------------*/
      if (title.StartsWith("_")) {
        title                   = title.Substring(1);
      }

      /*------------------------------------------------------------------------------------------------------------------------
      | Add a space between words
      \-----------------------------------------------------------------------------------------------------------------------*/
      title                     = Regex.Replace(title, "([a-z])_?([A-Z])", "$1 $2");

      /*------------------------------------------------------------------------------------------------------------------------
      | Return the title, with the first letter also uppercased
      \-----------------------------------------------------------------------------------------------------------------------*/
      return textInfo.ToTitleCase(title);
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
      lock (_syncRoot) {
        using (StreamWriter streamWriter = File.AppendText(LogLocation)) {
          streamWriter.WriteLine("// ========================================================== //");
          streamWriter.Write("\r\n  HTTP Request Log: ");
          streamWriter.WriteLine("{0} {1}", pacificNow.ToLongTimeString(), pacificNow.ToLongDateString());
          streamWriter.WriteLine();
          streamWriter.WriteLine("{0}", logOutput);
          streamWriter.WriteLine();
        }
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
      lock (_syncRoot) {
        using (StreamWriter streamWriter = File.AppendText(LogLocation)) {
          streamWriter.WriteLine("// ========================================================== //");
          streamWriter.Write("\r\n  " + logHeading + ": ");
          streamWriter.WriteLine("{0} {1}", pacificNow.ToLongTimeString(), pacificNow.ToLongDateString());
          streamWriter.WriteLine();
          streamWriter.WriteLine("  {0}", logMessage);
          streamWriter.WriteLine();
        }
      }

    }

  } // Class
} // Namespace