CREATE TABLE [dbo].[Product]
(
    [ProductId]  INT            IDENTITY (1, 1) NOT NULL,
    [Sku]        VARCHAR (32)   NOT NULL,
    [Name]       NVARCHAR (200) NOT NULL,
    [UnitPrice]  DECIMAL (18, 4) NOT NULL,
    [IsActive]   BIT            CONSTRAINT [DF_Product_IsActive] DEFAULT ((1)) NOT NULL,
    CONSTRAINT [PK_Product] PRIMARY KEY CLUSTERED ([ProductId] ASC),
    CONSTRAINT [UQ_Product_Sku] UNIQUE NONCLUSTERED ([Sku] ASC),
    CONSTRAINT [CK_Product_UnitPrice] CHECK ([UnitPrice] >= (0))
);
