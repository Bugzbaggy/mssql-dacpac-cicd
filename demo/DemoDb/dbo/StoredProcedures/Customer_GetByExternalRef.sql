CREATE PROCEDURE [dbo].[Customer_GetByExternalRef]
    @ExternalRef NVARCHAR (64)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  c.[CustomerId],
            c.[ExternalRef],
            c.[DisplayName],
            c.[CreatedUtc]
    FROM    [dbo].[Customer] AS c
    WHERE   c.[ExternalRef] = @ExternalRef;
END
