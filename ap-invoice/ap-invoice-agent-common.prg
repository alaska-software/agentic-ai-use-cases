//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Shared domain layer + helpers for the ApInvoiceAgent example
/// (LOB use case - Accounts Payable Invoice Automation).
///
/// ap-invoice-agent.prg supplies the agent class; ap-invoice-main.prg has
/// Main(). This file provides the domain/blackboard types, demo vendor master,
/// and demo PO book.
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

// ---------------------------------------------------------------------------
// Domain / blackboard types
//
// Every type the LLM populates derives from AbstractCard so that
// PromptRunner:createObject() can bind a parsed JSON reply onto it by member
// name. Init() bodies are NIL-safe: the framework instantiates them with no
// arguments when building the JSON schema hint.
// ---------------------------------------------------------------------------

/// <summary>
/// InvoiceSource - the run input handed to the agent by the driver.
/// </summary>
///
CLASS InvoiceSource FROM AbstractCard
   EXPORTED:
   VAR text
   VAR imagePath
   VAR label
   METHOD init()
   METHOD hasImage()
   METHOD hasText()
ENDCLASS

METHOD InvoiceSource:init()
   ::text      := ""
   ::imagePath := ""
   ::label     := ""
RETURN Self

METHOD InvoiceSource:hasImage()
RETURN !Empty( ::imagePath )

METHOD InvoiceSource:hasText()
RETURN !Empty( ::text )


/// <summary>
/// InvoiceData - LLM-populated invoice fields plus a retry counter managed
/// by the Extract action. Derives from AbstractCard so CreateObject()
/// can bind the JSON response onto it by member name. The attempt field is
/// NOT extracted by the LLM; the action overwrites it with its own counter.
/// </summary>
///
CLASS InvoiceData FROM AbstractCard
   EXPORTED:
   VAR vendor
   VAR invoiceNumber
   VAR poNumber
   VAR date
   VAR amount
   VAR currency
   VAR bankAccount
   VAR recipient
   CLASS METHOD initClass()
   METHOD init()
   ENDCLASS

   CLASS METHOD InvoiceData:initClass()
   ::addHint( "vendor",        "C", "the supplier or vendor name" )
   ::addHint( "invoiceNumber", "C", "the invoice identifier" )
   ::addHint( "poNumber",      "C", "the purchase order number, empty string if absent" )
   ::addHint( "date",          "D", "the invoice date as YYYYMMDD string, e.g. 20260115 — no separators" )
   ::addHint( "amount",        "N", "the total invoice amount as a raw JSON number, e.g. 1250.00" )
   ::addHint( "currency",      "C", "the ISO 4217 currency code, e.g. EUR, GBP" )
   ::addHint( "bankAccount",   "C", "the IBAN or account number for payment, empty string if absent" )
   ::addHint( "recipient",     "C", "the invoice recipient name, empty string if not stated" )
RETURN Self

METHOD InvoiceData:init()
   ::vendor        := ""
   ::invoiceNumber := ""
   ::poNumber      := ""
   ::date          := CToD( "" )
   ::amount        := 0
   ::currency      := ""
   ::bankAccount   := ""
   ::recipient     := ""
RETURN Self


/// <summary>
/// ExtractionValidation - result of the deterministic validation step that
/// decides whether the LLM's extraction is complete enough to proceed. Mirrors
/// ValidationResult in the SQL generator but names itself for the AP domain.
/// </summary>
///
CLASS ExtractionValidation FROM AbstractValidationResult
ENDCLASS


/// <summary>
/// VendorMatchSuggestion - LLM output for the fuzzy vendor match step.
/// CreateObject() binds the model's reply onto it; ProposeVendorMatch then
/// resolves vendorId to a full VendorRecord before building the VendorProposal.
/// </summary>
///
CLASS VendorMatchSuggestion FROM AbstractCard
   EXPORTED:
   VAR vendorId
   VAR reason
   CLASS METHOD initClass()
   METHOD init()
   ENDCLASS

   CLASS METHOD VendorMatchSuggestion:initClass()
   ::addHint( "vendorId", "C", "ID of the best matching vendor from the list, empty string if no confident match" )
   ::addHint( "reason",   "C", "brief explanation of the proposed match or why no match was found" )
RETURN Self

METHOD VendorMatchSuggestion:init()
   ::vendorId := ""
   ::reason   := ""
RETURN Self


/// <summary>
/// VendorRecord - deterministic vendor lookup result. Not LLM-populated but
/// derives from AbstractCard for consistency with the rest of the layer.
/// </summary>
///
CLASS VendorRecord FROM AbstractCard
   EXPORTED:
   VAR id
   VAR name
   VAR bankAccount
   VAR taxId
   VAR active
   METHOD init()
ENDCLASS

METHOD VendorRecord:init()
   ::id          := ""
   ::Name        := ""
   ::bankAccount := ""
   ::taxId       := ""
   ::active      := .F.
RETURN Self


/// <summary>
/// VendorProposal - intermediate blackboard value produced by ProposeVendorMatch.
/// Carries the resolved VendorRecord and the LLM's reasoning, ready to be
/// presented as a VendorApprovalRequest at the awaitVendorApproval terminal.
/// </summary>
///
CLASS VendorProposal FROM AbstractCard
   EXPORTED:
   VAR proposedVendor   // VendorRecord resolved from the LLM suggestion
   VAR reason           // LLM reasoning text
   METHOD init()
ENDCLASS

METHOD VendorProposal:init()
   ::proposedVendor := NIL
   ::reason         := ""
RETURN Self


/// <summary>
/// DuplicateCheck - result of the posted-invoice ledger lookup.
/// </summary>
///
CLASS DuplicateCheck FROM AbstractCard
   EXPORTED:
   VAR duplicate
   VAR existingDocId
   METHOD init()
ENDCLASS

METHOD DuplicateCheck:init()
   ::duplicate     := .F.
   ::existingDocId := ""
RETURN Self


/// <summary>
/// ThreeWayMatch - the full decision output of MatchToPO. All three routing
/// booleans are pre-computed here so guards read them directly without
/// recomputing. This mirrors TicketClassification in the support-triage example.
/// </summary>
///
CLASS ThreeWayMatch FROM AbstractCard
   EXPORTED:
   VAR poFound
   VAR amountDelta
   VAR tolerance
   VAR withinTolerance
   VAR autoPostable
   VAR needsApproval
   VAR hardMismatch
   VAR reason
   METHOD init()
ENDCLASS

METHOD ThreeWayMatch:init()
   ::poFound         := .F.
   ::amountDelta     := 0
   ::tolerance       := 0
   ::withinTolerance := .F.
   ::autoPostable    := .F.
   ::needsApproval   := .F.
   ::hardMismatch    := .F.
   ::reason          := ""
RETURN Self


/// <summary>
/// PostingResult - auto-post terminal output (ledger stub, no real I/O).
/// </summary>
///
CLASS PostingResult FROM AbstractCard
   EXPORTED:
   VAR ledgerEntryId
   VAR postedAt
   VAR message
   METHOD init()
ENDCLASS

METHOD PostingResult:init()
   ::ledgerEntryId := ""
   ::postedAt      := ""
   ::message       := ""
RETURN Self


/// <summary>
/// ApprovalRequest - routeForApproval terminal output. The message field
/// carries the LLM-drafted approval request text ready to send to the approver.
/// </summary>
///
CLASS ApprovalRequest FROM AbstractCard
   EXPORTED:
   VAR queue
   VAR priority
   VAR reason
   VAR message   // LLM-drafted approval request text
   METHOD init()
ENDCLASS

METHOD ApprovalRequest:init()
   ::queue    := ""
   ::priority := ""
   ::reason   := ""
   ::message  := ""
RETURN Self


/// <summary>
/// VendorApprovalRequest - awaitVendorApproval terminal output.
/// Packages the LLM's vendor match proposal for a human to review and act on.
/// </summary>
///
CLASS VendorApprovalRequest FROM AbstractCard
   EXPORTED:
   VAR proposedVendor   // VendorRecord — the LLM's candidate
   VAR reason           // LLM reasoning for the match
   VAR invoiceVendor    // original vendor name as it appeared on the invoice
   METHOD init()
ENDCLASS

METHOD VendorApprovalRequest:init()
   ::proposedVendor := NIL
   ::reason         := ""
   ::invoiceVendor  := ""
RETURN Self


/// <summary>
/// ExceptionTicket - raiseException terminal output.
/// </summary>
///
CLASS ExceptionTicket FROM AbstractCard
   EXPORTED:
   VAR category
   VAR summary
   VAR sourceLabel
   METHOD init()
ENDCLASS

METHOD ExceptionTicket:init()
   ::category    := ""
   ::summary     := ""
   ::sourceLabel := ""
RETURN Self


// ---------------------------------------------------------------------------
// Data providers
//
// Base classes define the interface; Demo subclasses supply in-memory fixtures.
// A later iteration can swap them for DBF-backed implementations without
// touching the agent flow.
// ---------------------------------------------------------------------------

CLASS VendorMaster
   EXPORTED:
   METHOD findByName( cName )
   METHOD findByBank( cIban )
   METHOD findById( cId )
   METHOD getActiveVendors()
ENDCLASS

METHOD VendorMaster:findByName( cName )
   UNUSED( cName )
RETURN NIL

METHOD VendorMaster:findByBank( cIban )
   UNUSED( cIban )
RETURN NIL

METHOD VendorMaster:findById( cId )
   UNUSED( cId )
RETURN NIL

METHOD VendorMaster:getActiveVendors()
RETURN {}


CLASS DemoVendorMaster FROM VendorMaster
   EXPORTED:
   VAR rows
   METHOD init()
   METHOD findByName( cName )
   METHOD findByBank( cIban )
   METHOD findById( cId )
   METHOD getActiveVendors()
ENDCLASS

METHOD DemoVendorMaster:init()
   LOCAL oV

   ::rows := {}

   oV              := VendorRecord():New()
   oV:id          := "V-100"
   oV:Name        := "Acme Corp"
   oV:bankAccount := "GB29NWBK60161331926819"
   oV:taxId       := "GB123456789"
   oV:active      := .T.
   AAdd( ::rows, oV )

   oV              := VendorRecord():New()
   oV:id          := "V-101"
   oV:Name        := "Contoso Ltd"
   oV:bankAccount := "DE89370400440532013000"
   oV:taxId       := "DE987654321"
   oV:active      := .T.
   AAdd( ::rows, oV )

   oV              := VendorRecord():New()
   oV:id          := "V-102"
   oV:Name        := "Northwind Traders"
   oV:bankAccount := "FR7630006000011234567890189"
   oV:taxId       := "FR12345678901"
   oV:active      := .T.
   AAdd( ::rows, oV )

   oV              := VendorRecord():New()
   oV:id          := "V-999"
   oV:Name        := "Fabrikam Inc"
   oV:bankAccount := "US00CITI0000000012345678"
   oV:taxId       := "US-EIN-99"
   oV:active      := .F.
   AAdd( ::rows, oV )

RETURN Self

METHOD DemoVendorMaster:findByName( cName )
   LOCAL cUp := Upper( AllTrim( If( cName == NIL, "", cName ) ) )
   LOCAL nI
   FOR nI := 1 TO Len( ::rows )
      IF Upper( AllTrim( ::rows[nI]:Name ) ) == cUp
         RETURN ::rows[nI]
      ENDIF
   NEXT
RETURN NIL

METHOD DemoVendorMaster:findByBank( cIban )
   LOCAL cTrimmed := AllTrim( If( cIban == NIL, "", cIban ) )
   LOCAL nI
   FOR nI := 1 TO Len( ::rows )
      IF AllTrim( ::rows[nI]:bankAccount ) == cTrimmed
         RETURN ::rows[nI]
      ENDIF
   NEXT
RETURN NIL

METHOD DemoVendorMaster:findById( cId )
   LOCAL cUp := Upper( AllTrim( If( cId == NIL, "", cId ) ) )
   LOCAL nI
   FOR nI := 1 TO Len( ::rows )
      IF Upper( AllTrim( ::rows[nI]:id ) ) == cUp
         RETURN ::rows[nI]
      ENDIF
   NEXT
RETURN NIL

METHOD DemoVendorMaster:getActiveVendors()
   LOCAL aActive := {}
   LOCAL nI
   FOR nI := 1 TO Len( ::rows )
      IF ::rows[nI]:active
         AAdd( aActive, ::rows[nI] )
      ENDIF
   NEXT
RETURN aActive


CLASS PurchaseOrderBook
   EXPORTED:
   METHOD findByNumber( cPo )
   METHOD isInvoiceRegistered( cVendorId, cInvoiceNumber )
ENDCLASS

METHOD PurchaseOrderBook:findByNumber( cPo )
   UNUSED( cPo )
RETURN NIL

METHOD PurchaseOrderBook:isInvoiceRegistered( cVendorId, cInvoiceNumber )
   UNUSED( cVendorId )
   UNUSED( cInvoiceNumber )
RETURN .F.


CLASS DemoPurchaseOrderBook FROM PurchaseOrderBook
   EXPORTED:
   VAR orders
   VAR posted
   METHOD init()
   METHOD findByNumber( cPo )
   METHOD isInvoiceRegistered( cVendorId, cInvoiceNumber )
ENDCLASS

METHOD DemoPurchaseOrderBook:init()
   LOCAL oPo1
   LOCAL oPo2
   LOCAL oPo3
   LOCAL oLed

   oPo1          := DataObject():New()
   oPo1:poNumber := "PO-1001"
   oPo1:vendorId := "V-100"
   oPo1:total    := 1250.00
   oPo1:currency := "GBP"
   oPo1:received := .T.

   oPo2          := DataObject():New()
   oPo2:poNumber := "PO-1002"
   oPo2:vendorId := "V-101"
   oPo2:total    := 3400.00
   oPo2:currency := "EUR"
   oPo2:received := .T.

   oPo3          := DataObject():New()
   oPo3:poNumber := "PO-1003"
   oPo3:vendorId := "V-102"
   oPo3:total    := 275.00
   oPo3:currency := "EUR"
   oPo3:received := .T.

   oLed                := DataObject():New()
   oLed:vendorId       := "V-100"
   oLed:invoiceNumber  := "INV-DUP-42"

   ::orders := { oPo1, oPo2, oPo3 }
   ::posted := { oLed }
RETURN Self

METHOD DemoPurchaseOrderBook:findByNumber( cPo )
   LOCAL cUp := Upper( AllTrim( If( cPo == NIL, "", cPo ) ) )
   LOCAL nI
   FOR nI := 1 TO Len( ::orders )
      IF Upper( AllTrim( ::orders[nI]:poNumber ) ) == cUp
         RETURN ::orders[nI]
      ENDIF
   NEXT
RETURN NIL

METHOD DemoPurchaseOrderBook:isInvoiceRegistered( cVendorId, cInvoiceNumber )
   LOCAL nI
   FOR nI := 1 TO Len( ::posted )
      IF ::posted[nI]:vendorId      == cVendorId .AND. ;
         ::posted[nI]:invoiceNumber == cInvoiceNumber
         RETURN .T.
      ENDIF
   NEXT
RETURN .F.


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// XML config loading
//
// Invoice sources are read from an XML file (ap-invoice-samples.config) with
// the Xbase++ XmlSimpleParser(). Document shape:
//
//   <invoices>
//     <invoice><label/><text/><imagePath/></invoice>
//     ...
//   </invoices>
//
// The <internal> element is ignored by the loader; it is metadata for the
// reader, describing what each scenario exercises (same convention as
// support-triage-emails.config).
// ---------------------------------------------------------------------------

/// <summary>
/// Read the XML config and turn each invoice element into an InvoiceSource.
/// </summary>
/// <remarks>
/// Returns an empty array (and prints why) when the file is missing/empty or
/// the XML is malformed.
/// </remarks>
/// <param name="cConfigFile">path to the XML config file</param>
/// <returns>array of InvoiceSource</returns>
///
FUNCTION LoadInvoiceSources( cConfigFile )
   LOCAL cXml := MemoRead( cConfigFile )
   LOCAL oXml
   LOCAL aNodes
   LOCAL aOut := {}
   LOCAL nI
   LOCAL oError

   IF Empty( cXml )
      ? "Config file not found or empty:", cConfigFile
      RETURN aOut
   ENDIF

   BEGIN TRY
      oXml   := XmlSimpleParser( cXml )
      aNodes := oXml:invoices:invoice

      IF ValType( aNodes ) == "O"
         aNodes := { aNodes }
      ENDIF

      IF ValType( aNodes ) != "A"
        ? "Error: Config w/a"
        Break()
      ENDIF

      FOR nI := 1 TO Len( aNodes )
         AAdd( aOut, NodeToInvoiceSource( aNodes[nI] ) )
      NEXT
   RECOVER USING oError
      ? "Failed to parse " + cConfigFile + ":", oError:description
      aOut := {}
   END

RETURN aOut


/// <summary>
/// Build an InvoiceSource from an XML invoice node.
/// </summary>
/// <remarks>
/// Leaf elements are read as members (XmlSimpleParser idiom) and AllTrim()-ed
/// to drop indentation whitespace. ANSI-to-UTF-8 conversion is handled by
/// the framework at the HTTP boundary.
/// </remarks>
/// <param name="oNode">parsed XML invoice node</param>
/// <returns>InvoiceSource</returns>
///
FUNCTION NodeToInvoiceSource( oNode )
   LOCAL oSrc := InvoiceSource():New()
   oSrc:text      := IIF( ValType( oNode:text      ) == "C", AllTrim( oNode:text      ), "" )
   oSrc:imagePath := IIF( ValType( oNode:imagePath ) == "C", AllTrim( oNode:imagePath ), "" )
   oSrc:label     := AllTrim( oNode:label )
RETURN oSrc


// ---------------------------------------------------------------------------
// Personas
// ---------------------------------------------------------------------------

CLASS ApInvoicePersonas

   EXPORTED:
   CLASS METHOD extractor()
   CLASS METHOD vendorMatcher()
   CLASS METHOD approvalDrafter()

ENDCLASS

/// <summary>
/// Persona for the invoice field extraction step.
/// </summary>
///
CLASS METHOD ApInvoicePersonas:extractor()
RETURN RoleGoalBackstory():create( ;
   "Invoice extraction specialist",                                            ;
   "Extract structured invoice fields from text or image input",               ;
   "Meticulous about totals, currencies, and matching PO numbers" )

/// <summary>
/// Persona for the fuzzy vendor name matching step.
/// </summary>
///
CLASS METHOD ApInvoicePersonas:vendorMatcher()
RETURN RoleGoalBackstory():create( ;
   "Vendor master data specialist",                                            ;
   "Match invoice vendor names to the correct vendor master record",           ;
   "Recognises abbreviations, trading names, and common spelling variants" )

/// <summary>
/// Persona for drafting approval request messages.
/// </summary>
///
CLASS METHOD ApInvoicePersonas:approvalDrafter()
RETURN RoleGoalBackstory():create( ;
   "AP business communication specialist",                                     ;
   "Draft concise professional approval request messages",                     ;
   "Clear, action-oriented, includes all relevant invoice details" )
